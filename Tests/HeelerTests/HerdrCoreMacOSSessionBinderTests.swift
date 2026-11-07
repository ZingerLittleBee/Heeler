import Foundation
import Testing

@testable import Heeler

/// Binding on a macOS core Host from what the macOS reads show (ADR 0034). The rows
/// are `host-evidence/macos/vm-26.5.json`, a throwaway macOS 26.5 VM with no sign-in
/// and SIP disabled, and `MacOSProcessTable` reports them as the macOS script does.
@Suite("herdr-core Chat on macOS, binder")
struct HerdrCoreMacOSSessionBinderTests {
    private nonisolated static let home = "/Users/admin"
    private nonisolated static let lab = "/Users/admin/lab/iso"
    private nonisolated static let openCodeID = "ses_e66b88ba5ffeAbCdEfGhIjKlMn"
    private nonisolated static let piFile =
        "\(lab)/pi085/agent/sessions/--Users-admin-lab-iso-projects-pi--/2026-11-01T22-42-44-916Z_ccfe7187-4ea6-468d-9555-83c3827f9cd0.jsonl"
    private nonisolated static let ompLabelFile =
        "\(lab)/omp/home/.omp/agent/sessions/--Users-admin-lab-iso-projects-omp--/2026-11-01T22-44-22-065Z_01a19949-05b1-77c6-ad62-e18bcc1b60f9.jsonl"
    private nonisolated static let ompBreadcrumbFile =
        "\(lab)/omp/home/.omp/agent/sessions/--Users-admin-lab-iso-projects-omp--/2026-11-01T22-45-39-428Z_01a1994a-33e4-7580-a399-bc030b312a13.jsonl"

    /// One scene for each program, and what the VM showed it bound to.
    private nonisolated static let exact: [(scene: String, program: ChatProgram, evidence: ChatSessionEvidence)] = [
        (
            "claude-direct", .claude,
            .bound(
                sessionID: "0d8ecfef-5bc7-4f7d-af22-2c185d16d85c", transcriptRoot: "\(lab)/claude/config",
                directory: "\(lab)/projects/claude")
        ),
        (
            "codex-after-reply", .codex,
            .bound(
                sessionID: "01a19946-4788-7402-b7ad-a538689feda9", transcriptRoot: "\(lab)/codex/codex-home",
                directory: "\(lab)/projects/codex")
        ),
        (
            "grok", .grok,
            .bound(
                sessionID: "c3b87b14-d6bf-41ed-b273-5594972f9bbf", transcriptRoot: "\(lab)/grok/grok-home",
                directory: "\(lab)/projects/grok")
        ),
        ("opencode", .opencode, .bound(sessionID: openCodeID, transcriptRoot: nil, directory: nil)),
        ("pi-extension", .pi, .bound(sessionID: piFile, transcriptRoot: "\(lab)/pi085/agent/sessions", directory: nil)),
        (
            "omp-extension", .omp,
            .bound(sessionID: ompLabelFile, transcriptRoot: "\(lab)/omp/home/.omp/agent/sessions", directory: nil)
        ),
    ]

    private actor LabelLog {
        var cleared: [String] = []
        func clear(_ names: [String]) { cleared += names }
    }

    private struct Rig {
        let scene: HostEvidenceFixture.Scene
        let table: MacOSProcessTable
        let files = VirtualHostFiles(home: HerdrCoreMacOSSessionBinderTests.home)
        let log = LabelLog()

        init(_ name: String) async throws {
            scene = try HostEvidenceFixture.named("macos/vm-26.5").scene(name)
            table = MacOSProcessTable(scene.processes ?? [])
            for (path, text) in scene.files ?? [:] { await files.write(text, at: path) }
        }

        /// The core's record as recorded, with these labels added, and for OpenCode the
        /// label Heeler's launch writes before any process exists.
        func record(
            labels: [String: String] = [:], foreground: (pid: Int, name: String, argv: [String])? = nil
        ) throws -> HerdrCoreTerminalRecord {
            guard case .object(var fields) = try #require(scene.record) else {
                throw HostEvidenceFixture.MissingScene(name: "\(scene.name) record")
            }
            var all = labels
            if case .object(let recorded)? = fields["labels"] {
                for (name, value) in recorded {
                    if case .string(let text) = value, all[name] == nil { all[name] = text }
                }
            }
            if scene.name == "opencode", labels.isEmpty { all[HerdrCoreLaunch.sessionHintLabel] = openCodeID }
            fields["labels"] = .object(all.mapValues(JSONValue.string))
            if let foreground {
                fields["foreground"] = .object([
                    "pid": .number(Double(foreground.pid)), "name": .string(foreground.name),
                    "argv": .array(foreground.argv.map(JSONValue.string)), "cwd": .string("\(lab)/projects"),
                ])
            }
            return try JSONDecoder().decode(
                HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(JSONValue.object(fields)))
        }

        func binder(_ program: ChatProgram, exact: Set<ChatProgram> = Set(ChatProgram.allCases)) -> HerdrCoreSessionBinder {
            let table = table
            let log = log
            var binder = HerdrCoreSessionBinder(
                program: program,
                processes: { try await table.read($0) },
                files: files.hostFiles(),
                clearLabels: { await log.clear($0.keys.sorted()) })
            binder.hostSystem = .macOS
            binder.macOSExactPrograms = exact
            return binder
        }

        /// The same rows through a Linux Host's reads.
        func linuxBinder(_ program: ChatProgram, startOverride: String? = nil) async -> HerdrCoreSessionBinder {
            let linux = ScriptedProcessTable()
            for row in scene.processes ?? [] {
                var process = row.process
                if let startOverride { process.start = startOverride }
                await linux.add(process)
            }
            let log = log
            return HerdrCoreSessionBinder(
                program: program,
                processes: { try await linux.read($0) },
                files: files.hostFiles(),
                clearLabels: { await log.clear($0.keys.sorted()) })
        }
    }

    private static func pick(session: String, file: String? = nil, pid: Int, start: String) -> String {
        HerdrCoreSessionHint.pickLabelValue(session: session, file: file, pid: pid, start: start) ?? ""
    }

    private static func cannotTell(_ program: ChatProgram) -> ChatSessionEvidence {
        .unavailable(.cannotTellSession(program))
    }

    // MARK: Exact evidence

    @Test(arguments: exact)
    func theRecordedEvidenceBinds(_ entry: (scene: String, program: ChatProgram, evidence: ChatSessionEvidence)) async throws {
        let rig = try await Rig(entry.scene)

        #expect(try await rig.binder(entry.program).check(try rig.record()) == entry.evidence)
        #expect(await rig.log.cleared.isEmpty)
    }

    // MARK: Claude Code

    @Test func aRegistryEntryFromAnotherStartBindsNothing() async throws {
        let rig = try await Rig("claude-direct")
        let entry = "\(Self.lab)/claude/config/sessions/997.json"
        let recorded = try #require(rig.scene.files?[entry])
        // The same moment in Claude's own zone rather than UTC, and a second later.
        for start in ["Mon Nov  2 07:39:55 2026", "Sun Nov  1 22:39:56 2026"] {
            await rig.files.write(
                recorded.replacingOccurrences(of: "Sun Nov  1 22:39:55 2026", with: start), at: entry)

            #expect(try await rig.binder(.claude).check(try rig.record()) == Self.cannotTell(.claude))
        }
    }

    @Test func claudeCodeUnderAShellBindsTheProcessBehindIt() async throws {
        let rig = try await Rig("claude-under-zsh")

        let evidence = try await rig.binder(.claude).check(try rig.record())

        #expect(
            evidence
                == .bound(
                    sessionID: "fa8a82d1-1c60-47cf-ae42-ca8457940ef0", transcriptRoot: "\(Self.lab)/claude/config",
                    directory: "\(Self.lab)/projects/claude"))
    }

    /// A launcher that stays: the walk goes on to the process of the same scope, and a
    /// process of another scope counts for nothing.
    @Test func descendantsAreFollowedByTheirScope() async throws {
        let rig = try await Rig("claude-under-zsh")
        let launcher = (pid: 1059, name: "node", argv: ["node", "launcher"])

        #expect(try await rig.binder(.claude).check(try rig.record(foreground: launcher)) == .bound(
            sessionID: "fa8a82d1-1c60-47cf-ae42-ca8457940ef0", transcriptRoot: "\(Self.lab)/claude/config",
            directory: "\(Self.lab)/projects/claude"))

        let other = try await Rig("claude-under-zsh")
        var rows = try #require(other.scene.processes)
        rows[1].environment["HC_SCOPE"] = "another-terminal"
        let moved = MacOSProcessTable(rows)
        var binder = other.binder(.claude)
        binder.processes = { try await moved.read($0) }
        #expect(try await binder.check(try other.record(foreground: launcher)) == Self.cannotTell(.claude))
    }

    // MARK: Codex

    @Test func codexBeforeItsFirstPromptHoldsOnlyALock() async throws {
        let rig = try await Rig("codex-before-prompt")

        #expect(try await rig.binder(.codex).check(try rig.record()) == Self.cannotTell(.codex))
        #expect(await rig.files.reads.isEmpty)
    }

    /// The daemon holds the rollout and the Agent none, so nothing is read of it.
    @Test func aManagedDaemonIsSkippedForTheReopenMessage() async throws {
        let rig = try await Rig("codex-shared-daemon")

        #expect(try await rig.binder(.codex).check(try rig.record()) == .unavailable(.codexSharedDaemon))
        #expect(await rig.files.reads.isEmpty)
        #expect(try await rig.binder(.codex).candidates(of: try rig.record()) == .sharedDaemon)
    }

    /// A second window on a daemon that is already running has none under it.
    @Test func aCodexLaunchOnARunningDaemonFindsItsSocket() async throws {
        let rig = try await Rig("codex-shared-daemon")
        for pid in [2852, 2863, 2859, 2860, 2861] { await rig.table.remove(pid) }

        #expect(try await rig.binder(.codex).check(try rig.record()) == Self.cannotTell(.codex))

        await rig.files.write(
            "", at: "\(Self.lab)/codexd/codex-home/app-server-control/app-server-control.sock")
        #expect(try await rig.binder(.codex).check(try rig.record()) == .unavailable(.codexSharedDaemon))
    }

    // MARK: Grok Build

    private nonisolated static func grokRow(pid: Int = 1857, pidStart: Int64) -> String {
        """
        {"session_id":"c3b87b14-d6bf-41ed-b273-5594972f9bbf","pid":\(pid),"pid_start":\(pidStart),\
        "cwd":"\(lab)/projects/grok","opened_at":"2026-11-01T22:42:25.687253Z"}
        """
    }

    /// `pid_start` is microseconds since the epoch there, and the read says the second
    /// (1793572940 is `Sun Nov  1 22:42:20 2026` UTC).
    @Test(arguments: [Int64(1_793_572_940_135_416), 1_793_572_940_000_000, 1_793_572_940_999_999])
    func aGrokRowOfThatSecondBinds(_ pidStart: Int64) async throws {
        let rig = try await Rig("grok")
        await rig.files.write(
            "[\(Self.grokRow(pidStart: pidStart))]", at: "\(Self.lab)/grok/grok-home/active_sessions.json")

        let evidence = try await rig.binder(.grok).check(try rig.record())

        guard case .bound(let session, _, _) = evidence else {
            Issue.record("Expected a binding, got \(evidence)")
            return
        }
        #expect(session == "c3b87b14-d6bf-41ed-b273-5594972f9bbf")
    }

    @Test(arguments: [
        grokRow(pidStart: 1_793_572_941_000_000), grokRow(pidStart: 1_793_572_939_999_999),
        // Seconds, or Linux's ticks, are not this form.
        grokRow(pidStart: 1_793_572_940), grokRow(pidStart: 145585), grokRow(pid: 1858, pidStart: 1_793_572_940_135_416),
        // After `/new` nothing says which the screen shows.
        grokRow(pidStart: 1_793_572_940_135_416) + "," + grokRow(pidStart: 1_793_572_940_135_416),
    ])
    func aGrokRowOfAnythingElseBindsNothing(_ rows: String) async throws {
        let rig = try await Rig("grok")
        await rig.files.write("[\(rows)]", at: "\(Self.lab)/grok/grok-home/active_sessions.json")

        #expect(try await rig.binder(.grok).check(try rig.record()) == Self.cannotTell(.grok))
    }

    // MARK: OpenCode, Pi and Oh My Pi

    @Test func openCodesLaunchHintCountsOnlyWhileTheForegroundCarriesIt() async throws {
        let rig = try await Rig("opencode")
        let hint = [HerdrCoreLaunch.sessionHintLabel: Self.openCodeID]

        #expect(
            try await rig.binder(.opencode).check(try rig.record(labels: hint))
                == .bound(sessionID: Self.openCodeID, transcriptRoot: nil, directory: nil))
        #expect(
            try await rig.binder(.opencode).check(
                try rig.record(
                    labels: hint, foreground: (pid: 1924, name: "opencode", argv: ["/Users/admin/lab/bin/opencode"])))
                == Self.cannotTell(.opencode))
    }

    @Test func openCodesPluginLabelBindsOnlyForItsPidAndStart() async throws {
        let rig = try await Rig("opencode")
        let noHint = (pid: 1924, name: "opencode", argv: ["/Users/admin/lab/bin/opencode"])
        func label(pid: Int, start: String) -> [String: String] {
            ["heeler.session": #"{"session":"\#(Self.openCodeID)","pid":\#(pid),"start":"\#(start)"}"#]
        }

        #expect(
            try await rig.binder(.opencode).check(
                try rig.record(labels: label(pid: 1924, start: "Sun Nov  1 22:42:39 2026"), foreground: noHint))
                == .bound(sessionID: Self.openCodeID, transcriptRoot: nil, directory: nil))
        for stale in [label(pid: 1924, start: "Sun Nov  1 22:42:40 2026"), label(pid: 1925, start: "Sun Nov  1 22:42:39 2026")] {
            #expect(
                try await rig.binder(.opencode).check(try rig.record(labels: stale, foreground: noHint))
                    == Self.cannotTell(.opencode))
        }
        #expect(await rig.log.cleared == ["heeler.session", "heeler.session"])
    }

    @Test(arguments: [
        ("pi-extension", ChatProgram.pi, 2009, "Sun Nov  1 22:42:44 2026"),
        ("omp-extension", ChatProgram.omp, 2564, "Sun Nov  1 22:44:21 2026"),
    ])
    func anExtensionLabelBindsOnlyForItsPidAndStart(
        _ scene: String, _ program: ChatProgram, _ pid: Int, _ start: String
    ) async throws {
        let rig = try await Rig(scene)
        let recorded = try #require(try rig.record().labels["heeler.session"])
        let later = recorded.replacingOccurrences(of: start, with: "Sun Nov  1 23:00:00 2026")
        let elsewhere = recorded.replacingOccurrences(of: "\"pid\":\(pid)", with: "\"pid\":\(pid + 1)")

        for label in [later, elsewhere] {
            #expect(
                try await rig.binder(program).check(try rig.record(labels: ["heeler.session": label]))
                    == Self.cannotTell(program))
        }
        #expect(await rig.log.cleared == ["heeler.session", "heeler.session"])
    }

    /// The id Heeler started it with, while the launch's arguments still carry it,
    /// under the send guard a pick has.
    @Test func aPiHeelerStartedBindsFromItsLaunchHint() async throws {
        let rig = try await Rig("pi-extension")
        let id = "ccfe7187-4ea6-468d-9555-83c3827f9cd0"

        #expect(
            try await rig.binder(.pi).check(
                try rig.record(labels: [HerdrCoreLaunch.sessionHintLabel: id, "heeler.session": ""]))
                == .picked(sessionID: id, transcriptRoot: "\(Self.lab)/pi085/agent/sessions"))
    }

    /// `/dev/ttys006` files under `ttys006`, and only the open file proves it (ADR 0034):
    /// the breadcrumb is there before the first message, marked `fresh`.
    @Test func ohMyPisBreadcrumbBindsOnceItsFileIsHeld() async throws {
        let rig = try await Rig("omp-breadcrumb")
        #expect(
            try await rig.binder(.omp).check(try rig.record())
                == .bound(
                    sessionID: Self.ompBreadcrumbFile,
                    transcriptRoot: "\(Self.lab)/omp/home/.omp/agent/sessions", directory: nil))
        #expect(await rig.files.reads.map(\.path) == ["\(Self.lab)/omp/home/.omp/agent/terminal-sessions/ttys006"])

        let before = try await Rig("omp-before-prompt")
        #expect(try await before.binder(.omp).check(try before.record()) == Self.cannotTell(.omp))
    }

    /// On Linux `/dev/ttys0` is a serial port, not a Terminal.
    @Test func aLinuxHostReadsNoTerminalFromThatName() async throws {
        let rig = try await Rig("omp-breadcrumb")

        let evidence = try await rig.linuxBinder(.omp).check(try rig.record())

        #expect(evidence == Self.cannotTell(.omp))
    }

    // MARK: A walk that answered

    private static let zshAtPrompt = (pid: 1059, name: "zsh", argv: ["/bin/zsh", "-f"])

    /// macOS's walk says it answered, so a label's process no longer listed has left.
    @Test(arguments: ChatProgram.allCases)
    func aPickWhoseProcessLeftIsDropped(_ program: ChatProgram) async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.table.remove(1066)
        let label = Self.pick(session: Self.conversation(program), pid: 1066, start: "Sun Nov  1 22:40:03 2026")

        let evidence = try await rig.binder(program).check(
            try rig.record(labels: ["heeler.chat": label], foreground: Self.zshAtPrompt))

        #expect(evidence == Self.cannotTell(program))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    /// Apple's own shell on a SIP-on Mac, whose environment macOS withholds: the walk
    /// still says the process left.
    @Test(arguments: ChatProgram.allCases)
    func aPickWhoseProcessLeftIsDroppedAtAWithheldShell(_ program: ChatProgram) async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.table.remove(1066)
        await rig.table.withholdEnvironment(of: 1059)
        let label = Self.pick(session: Self.conversation(program), pid: 1066, start: "Sun Nov  1 22:40:03 2026")

        let evidence = try await rig.binder(program).check(
            try rig.record(labels: ["heeler.chat": label], foreground: Self.zshAtPrompt))

        #expect(evidence == Self.cannotTell(program))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    @Test(arguments: ChatProgram.allCases)
    func aPickStandsWhenTheWalkIsPastItsCap(_ program: ChatProgram) async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.table.goPastTheWalksCap()
        let label = Self.pick(session: Self.conversation(program), pid: 1066, start: "Sun Nov  1 22:40:03 2026")

        let evidence = try await rig.binder(program).check(
            try rig.record(labels: ["heeler.chat": label], foreground: Self.zshAtPrompt))

        #expect(evidence == .pickUnconfirmed(.cannotTellSession(program)))
        #expect(await rig.log.cleared.isEmpty)
    }

    @Test func aPickOnTheAgentBindsAfterTheWalkAnswered() async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.files.write("{}", at: "\(Self.lab)/claude/config/sessions/1066.json")
        let session = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
        let label = Self.pick(session: session, pid: 1066, start: "Sun Nov  1 22:40:03 2026")

        let evidence = try await rig.binder(.claude).check(try rig.record(labels: ["heeler.chat": label]))

        #expect(evidence == .picked(sessionID: session, transcriptRoot: "\(Self.lab)/claude/config"))
    }

    @Test func aPickForAnotherStartIsDropped() async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.files.write("{}", at: "\(Self.lab)/claude/config/sessions/1066.json")
        let label = Self.pick(
            session: "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11", pid: 1066, start: "Sun Nov  1 22:40:04 2026")

        let evidence = try await rig.binder(.claude).check(try rig.record(labels: ["heeler.chat": label]))

        #expect(evidence == Self.cannotTell(.claude))
        #expect(await rig.log.cleared == ["heeler.chat"])
    }

    private static func conversation(_ program: ChatProgram) -> String {
        switch program {
        case .opencode: openCodeID
        case .pi, .omp: "\(lab)/s/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.jsonl"
        case .claude, .codex, .grok, .agy: "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
        }
    }

    // MARK: The candidate list

    @Test func theListIsForTheProcessBehindTheShell() async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.files.write("{}", at: "\(Self.lab)/claude/config/sessions/1066.json")
        let session = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
        await rig.files.write(
            "{}\n", at: "\(Self.lab)/claude/config/projects/-Users-admin-lab-iso-projects-claude/\(session).jsonl")

        let answer = try await rig.binder(.claude).candidates(of: try rig.record())

        guard case .listed(let list) = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
        #expect(list.pid == 1066)
        #expect(list.start == "Sun Nov  1 22:40:03 2026")
        #expect(list.transcriptRoot == "\(Self.lab)/claude/config")
        #expect(list.candidates.map(\.sessionID) == [session])
    }

    @Test func aFileGrokHoldsIsListedFirst() async throws {
        let rig = try await Rig("grok")
        await rig.files.write("[]", at: "\(Self.lab)/grok/grok-home/active_sessions.json")

        let answer = try await rig.binder(.grok).candidates(of: try rig.record())

        guard case .listed(let list) = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
        #expect(list.candidates.first?.sessionID == "c3b87b14-d6bf-41ed-b273-5594972f9bbf")
        #expect(list.candidates.first?.origins == [.heldOpen])
    }

    @Test func aWalkPastItsCapListsNothing() async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.table.goPastTheWalksCap()

        #expect(try await rig.binder(.claude).candidates(of: try rig.record()) == .noProcess)
    }

    // MARK: A read the recorded observations left unconfirmed

    /// The scene and start each program binds from on Linux, whose reads give field 22.
    private nonisolated static let linuxStarts: [ChatProgram: String] = [.grok: "1793572940135416"]

    @Test(arguments: exact)
    func aProgramLeftUnconfirmedOffersCandidatesAndLinuxStillBinds(
        _ entry: (scene: String, program: ChatProgram, evidence: ChatSessionEvidence)
    ) async throws {
        let rig = try await Rig(entry.scene)
        let others = Set(ChatProgram.allCases).subtracting([entry.program])

        #expect(try await rig.binder(entry.program, exact: others).check(try rig.record()) == Self.cannotTell(entry.program))
        let answer = try await rig.binder(entry.program, exact: others).candidates(of: try rig.record())
        guard case .listed = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }

        let linux = await rig.linuxBinder(entry.program, startOverride: Self.linuxStarts[entry.program])
        #expect(try await linux.check(try rig.record()) == entry.evidence)
    }

    // MARK: Antigravity CLI

    /// agy 1.5.3 on a signed-in Mac, outside a core (`host-evidence/agy`): its rows
    /// through the macOS script's lines and the real parser, with a record naming agy
    /// as the Terminal's own process and its foreground.
    private static func agyBinder(
        _ scene: String, exact: Set<ChatProgram> = HostCapabilities.macOSExactCoreChatPrograms,
        configure: (MacOSProcessTable) async -> Void = { _ in }
    ) async throws -> (HerdrCoreSessionBinder, HerdrCoreTerminalRecord, VirtualHostFiles) {
        let scene = try HostEvidenceFixture.named("agy/presence-lock-1.5.3").scene(scene)
        let row = try #require(scene.processes?.first)
        let table = MacOSProcessTable([row])
        await configure(table)
        let files = VirtualHostFiles(home: "/Users/developer")
        var binder = HerdrCoreSessionBinder(
            program: .agy, processes: { try await table.read($0) }, files: files.hostFiles(), clearLabels: { _ in })
        binder.hostSystem = .macOS
        binder.macOSExactPrograms = exact
        let name = JSONValue.string("agy")
        let record = try JSONDecoder().decode(
            HerdrCoreTerminalRecord.self,
            from: try JSONEncoder().encode(
                JSONValue.object([
                    "address": .string("t1"), "cwd": .string("/Users/developer/lab"), "state": .string("live"),
                    "argv": .array([name]), "keep": .bool(true), "title": .string(""), "cols": .number(80),
                    "rows": .number(24), "name": .null, "reason": .null, "pid": .number(Double(row.pid)),
                    "labels": .object([:]),
                    "foreground": .object([
                        "pid": .number(Double(row.pid)), "name": name, "argv": .array([name]),
                        "cwd": .string("/Users/developer/lab"),
                    ]),
                ])))
        return (binder, record, files)
    }

    /// The reader's own macOS read of a probe's agy is what the macOS Host binds from.
    /// The owner's check in a core Terminal has not run, so no Mac offers it yet.
    @Test func antigravityBindsExactlyFromItsMacOSRead() async throws {
        #expect(HostCapabilities.macOSExactCoreChatPrograms.contains(.agy))
        #expect(!HostCapabilities.confirmedMacOSCoreChatPrograms.contains(.agy))
        let (binder, record, files) = try await Self.agyBinder("after-first-prompt")

        #expect(
            try await binder.check(record)
                == .bound(
                    sessionID: "95739799-ba8d-4e64-90ee-04991d45f22d",
                    transcriptRoot: "/Users/developer/.gemini/antigravity-cli", directory: nil))
        #expect(await files.reads.isEmpty)

        let (atPrompt, atPromptRecord, _) = try await Self.agyBinder("at-prompt")
        #expect(try await atPrompt.check(atPromptRecord) == Self.cannotTell(.agy))
    }

    /// Left out of the exact set, it reads as cannot tell and lists what it holds.
    @Test func antigravityLeftUnconfirmedListsWhatItHolds() async throws {
        let (binder, record, _) = try await Self.agyBinder(
            "follow-after-clear", exact: Set(ChatProgram.allCases).subtracting([.agy]))

        #expect(try await binder.check(record) == Self.cannotTell(.agy))
        let answer = try await binder.candidates(of: record)
        guard case .listed(let list) = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
        #expect(
            Set(list.candidates.map(\.sessionID))
                == ["3760d133-2936-4a32-95b4-8437ce7a8fbe", "3af3ed7f-0f65-423c-8ef4-69072caf1e06"])
        #expect(list.candidates.allSatisfy { $0.origins == [.heldOpen] })
    }

    /// A Mac with no `lsof` answers `-`, which says nothing held is known.
    @Test func antigravityWithOpenFilesThatCannotBeReadCannotTell() async throws {
        let (binder, record, _) = try await Self.agyBinder("after-first-prompt") {
            await $0.stopAnsweringOpenFiles()
        }

        #expect(try await binder.check(record) == Self.cannotTell(.agy))
        let answer = try await binder.candidates(of: record)
        guard case .listed(let list) = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
        #expect(list.candidates.isEmpty)
    }

    /// The one confirmation still works there.
    @Test func aPickBindsAProgramLeftUnconfirmed() async throws {
        let rig = try await Rig("pi-extension")
        let label = Self.pick(
            session: "ccfe7187-4ea6-468d-9555-83c3827f9cd0", file: Self.piFile, pid: 2009, start: "Sun Nov  1 22:42:44 2026")

        let evidence = try await rig.binder(.pi, exact: []).check(
            try rig.record(labels: ["heeler.chat": label]))

        #expect(evidence == .picked(sessionID: Self.piFile, transcriptRoot: "\(Self.lab)/pi085/agent/sessions"))
        #expect(await rig.log.cleared.isEmpty)
    }

    /// A Codex left unconfirmed still gets only the reopen message on the daemon.
    @Test func theDaemonIsStillSaidWhenCodexIsLeftUnconfirmed() async throws {
        let rig = try await Rig("codex-shared-daemon")

        #expect(try await rig.binder(.codex, exact: []).check(try rig.record()) == .unavailable(.codexSharedDaemon))
        #expect(try await rig.binder(.codex, exact: []).candidates(of: try rig.record()) == .sharedDaemon)
    }

    /// A read that answers `-` leaves what depends on it to the list.
    @Test(arguments: [("codex-after-reply", ChatProgram.codex), ("omp-breadcrumb", .omp)])
    func openFilesThatCannotBeReadLeaveTheList(_ scene: String, _ program: ChatProgram) async throws {
        let rig = try await Rig(scene)
        await rig.table.stopAnsweringOpenFiles()

        #expect(try await rig.binder(program).check(try rig.record()) == Self.cannotTell(program))
        let answer = try await rig.binder(program).candidates(of: try rig.record())
        guard case .listed = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
    }

    /// All but Codex, whose evidence is the file it holds.
    @Test(arguments: exact.filter { $0.program != .codex })
    func aStartThatCannotBeReadBindsNothing(
        _ entry: (scene: String, program: ChatProgram, evidence: ChatSessionEvidence)
    ) async throws {
        let rig = try await Rig(entry.scene)
        await rig.table.stopAnsweringStart()

        #expect(try await rig.binder(entry.program).check(try rig.record()) == Self.cannotTell(entry.program))
    }

    // MARK: Withheld scope

    /// A SIP-on Mac withholds `/bin/zsh`'s environment, and the Terminal's own process
    /// is usually that. The foreground then says the scope.
    @Test func aWithheldTerminalLeavesTheForegroundsScope() async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.table.withholdEnvironment(of: 1059)

        #expect(try await rig.binder(.claude).check(try rig.record()) == .bound(
            sessionID: "fa8a82d1-1c60-47cf-ae42-ca8457940ef0", transcriptRoot: "\(Self.lab)/claude/config",
            directory: "\(Self.lab)/projects/claude"))
    }

    /// A launcher of Apple's in the middle says no scope to follow, and nothing guesses.
    @Test func aWithheldForegroundBindsNothing() async throws {
        let rig = try await Rig("claude-under-zsh")
        await rig.table.withholdEnvironment(of: 1059)
        let launcher = (pid: 1059, name: "sh", argv: ["/bin/sh", "launcher"])

        #expect(try await rig.binder(.claude).check(try rig.record(foreground: launcher)) == Self.cannotTell(.claude))
        #expect(try await rig.binder(.claude).candidates(of: try rig.record(foreground: launcher)) == .noProcess)
    }

    /// A launcher that can be read says the scope, and what it runs through one of
    /// Apple's binaries is out of sight below it. It is not the Agent, so nothing can
    /// bind to its pid.
    @Test func anAppleBinaryBelowAReadableLauncherOffersNoList() async throws {
        let rig = try await Rig("claude-direct")
        let row = try #require(rig.scene.processes?.first)
        var titled = row.process
        titled.name = "node"
        await rig.table.add(titled)
        for (pid, parent, name) in [(77_001, row.pid, "sh"), (77_002, 77_001, "claude")] {
            await rig.table.add(
                ScriptedProcessTable.Process(pid: pid, parent: parent, name: name, start: row.start, environment: [:]))
            await rig.table.withholdEnvironment(of: pid)
        }
        let launcher = (pid: row.pid, name: "node", argv: ["node", "/opt/claude/cli.js"])

        #expect(try await rig.binder(.claude).check(try rig.record(foreground: launcher)) == Self.cannotTell(.claude))
        #expect(try await rig.binder(.claude).candidates(of: try rig.record(foreground: launcher)) == .noProcess)
    }

    /// Linux does not withhold, so an unreadable Terminal is still no scope there.
    @Test func aLinuxHostTakesOnlyTheTerminalsOwnScope() async throws {
        let rig = try await Rig("claude-under-zsh")
        let table = rig.table
        await table.withholdEnvironment(of: 1059)
        var binder = rig.binder(.claude)
        binder.hostSystem = .other

        #expect(try await binder.check(try rig.record()) == Self.cannotTell(.claude))
        #expect(await rig.files.reads.isEmpty)
    }

    // MARK: The budget

    @Test(arguments: exact)
    func aCheckCostsOneExecAndOneReadAndNamesItsVariables(
        _ entry: (scene: String, program: ChatProgram, evidence: ChatSessionEvidence)
    ) async throws {
        let rig = try await Rig(entry.scene)
        let key = "\(Self.lab)/claude/config/sessions/997.0123456789abcdef.key"
        await rig.files.write("not read", at: key)

        _ = try await rig.binder(entry.program).check(try rig.record())

        let requests = await rig.table.requests
        #expect(requests.count == 1)
        let reads = await rig.files.reads.map(\.path)
        #expect(reads.count <= 1)
        #expect(!reads.contains { $0.hasSuffix(".key") })
        #expect(await rig.files.listings.isEmpty)
        let request = try #require(requests.first)
        let asked = request.valuesOf + request.namesOf
        #expect(!asked.contains { $0.hasPrefix("HERDR_") })
        #expect(request.namesWithPrefix.isEmpty)
        #expect(asked.contains("HC_SCOPE"))
    }
}
