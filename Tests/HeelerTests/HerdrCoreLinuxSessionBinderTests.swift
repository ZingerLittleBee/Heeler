import Foundation
import Testing

@testable import Heeler

/// Binding on a Linux core Host from what a signed-in run on hc-lab showed (ADR 0034).
/// The rows are `host-evidence/linux/hc-lab-signed-in.json`, which kept only `HC_SCOPE` of
/// each environment, so the rig adds the `HOME` its paths show. The programs ran in the
/// real `HOME` and wrote under its default folders, so the rig sets no `CODEX_HOME`,
/// `GROK_HOME` or Pi variable.
@Suite("herdr-core Chat on Linux, signed-in recording")
struct HerdrCoreLinuxSessionBinderTests {
    private nonisolated static let home = "/data/home"

    private nonisolated static func cannotTell(_ program: ChatProgram) -> ChatSessionEvidence {
        .unavailable(.cannotTellSession(program))
    }

    /// Each scene, and what its evidence binds. The Oh My Pi without the extension never
    /// held its file in this recording, so its breadcrumb binds nothing.
    private nonisolated static let recorded: [(scene: String, program: ChatProgram, evidence: ChatSessionEvidence)] = [
        ("codex-before-prompt", .codex, cannotTell(.codex)),
        (
            "codex-after-reply", .codex,
            .bound(sessionID: "01900000-0000-7000-8000-000000000001", transcriptRoot: "\(home)/.codex", directory: nil)
        ),
        ("codex-shared-daemon", .codex, .unavailable(.codexSharedDaemon)),
        (
            "grok", .grok,
            .bound(
                sessionID: "00000000-0000-4000-8000-000000000003", transcriptRoot: "\(home)/.grok",
                directory: "\(home)/user/projects/grok")
        ),
        ("opencode", .opencode, .bound(sessionID: "ses_e6a000000004Abcdefghijklmn", transcriptRoot: nil, directory: nil)),
        (
            // The launch hint is watched as a pick is, since `/new` leaves it behind.
            "pi-launch", .pi,
            .picked(sessionID: "00000000-0000-4000-8000-000000000005", transcriptRoot: "\(home)/.pi/agent/sessions")
        ),
        ("omp-after-reply", .omp, cannotTell(.omp)),
        ("omp-fresh-breadcrumb", .omp, cannotTell(.omp)),
    ]

    private actor LabelLog {
        var cleared: [String] = []
        func clear(_ names: [String]) { cleared += names }
    }

    private struct Rig {
        let scene: HostEvidenceFixture.Scene
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: HerdrCoreLinuxSessionBinderTests.home)
        let log = LabelLog()

        init(_ name: String) async throws {
            scene = try HostEvidenceFixture.named("linux/hc-lab-signed-in").scene(name)
            for row in scene.processes ?? [] {
                var process = row.process
                process.environment["HOME"] = HerdrCoreLinuxSessionBinderTests.home
                await table.add(process)
            }
            for (path, text) in scene.files ?? [:] { await files.write(text, at: path) }
        }

        func record() throws -> HerdrCoreTerminalRecord {
            try JSONDecoder().decode(
                HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(try #require(scene.record)))
        }

        func binder(_ program: ChatProgram) -> HerdrCoreSessionBinder {
            let table = table
            let log = log
            return HerdrCoreSessionBinder(
                program: program,
                processes: { try await table.read($0) },
                files: files.hostFiles(),
                clearLabels: { await log.clear($0.keys.sorted()) })
        }
    }

    @Test(arguments: recorded)
    func theRecordedEvidenceBindsAsTheRunShowed(
        _ entry: (scene: String, program: ChatProgram, evidence: ChatSessionEvidence)
    ) async throws {
        let rig = try await Rig(entry.scene)

        #expect(try await rig.binder(entry.program).check(try rig.record()) == entry.evidence)
        #expect(await rig.log.cleared.isEmpty)
    }

    /// An exec that answers nothing tells nothing, so a launch hint the send guard
    /// watches stands, as a pick's label does, and Chat keeps the conversation it
    /// shows. One a guard dropped does not.
    @Test func aPiLaunchHintACheckCannotHoldStands() async throws {
        let rig = try await Rig("pi-launch")
        var binder = rig.binder(.pi)
        binder.processes = { _ in [:] }

        #expect(try await binder.check(try rig.record()) == .pickUnconfirmed(.cannotTellSession(.pi)))
        binder.isDroppedPick = { _ in true }
        #expect(try await binder.check(try rig.record()) == Self.cannotTell(.pi))
        #expect(await rig.log.cleared.isEmpty)
    }

    @Test(arguments: recorded)
    func aCheckCostsOneExecAndOneReadAndNamesItsVariables(
        _ entry: (scene: String, program: ChatProgram, evidence: ChatSessionEvidence)
    ) async throws {
        let rig = try await Rig(entry.scene)

        _ = try await rig.binder(entry.program).check(try rig.record())

        let requests = await rig.table.requests
        #expect(requests.count == 1)
        // Beyond that one read, only a Pi or Oh My Pi that can't tell looks for
        // Heeler's extension, which only chooses the reason's words.
        let reads = await rig.files.reads.map(\.path)
        let extensionLooks = reads.filter { $0.hasSuffix("/extensions/\(HostHelperScript.extensionFileName)") }
        #expect(reads.count - extensionLooks.count <= 1)
        #expect(extensionLooks.count <= (entry.evidence == Self.cannotTell(entry.program) ? 1 : 0))
        #expect(await rig.files.listings.isEmpty)
        let request = try #require(requests.first)
        let asked = request.valuesOf + request.namesOf
        #expect(!asked.contains { $0.hasPrefix("HERDR_") })
        #expect(request.namesWithPrefix.isEmpty)
        #expect(asked.contains("HC_SCOPE"))
    }

    // MARK: Antigravity CLI

    /// The Linux run of 2026-11-09 read agy's lock through `/proc/<pid>/fd` but kept
    /// no recording here. Its lock is `jetski/presence/lock_unix.go`'s on both
    /// systems, so these take the macOS recording (`host-evidence/agy`) with its paths
    /// moved under this Host's home, read the way a Linux Host reads them:
    /// `/proc/<pid>/fd` targets, which name the same files. The core's record of the
    /// foreground carries the recorded argv, or a bare `agy` where none was recorded.
    /// `files` and `argv` replace the row's.
    private nonisolated static func agyRig(
        _ scene: String, files: [String]? = nil, argv: [String]? = nil
    ) async throws -> (ScriptedProcessTable, HerdrCoreTerminalRecord) {
        let row = try #require(try HostEvidenceFixture.named("agy/presence-lock-1.5.3").scene(scene).processes?.first)
        var process = row.process
        process.environment["HOME"] = home
        process.openFiles = files ?? row.files.map { $0.replacingOccurrences(of: "/Users/developer", with: home) }
        let table = ScriptedProcessTable()
        await table.add(process)
        let name = JSONValue.string("agy")
        let foreground = (argv ?? (row.argv.isEmpty ? ["agy"] : row.argv)).map(JSONValue.string)
        let record = try JSONDecoder().decode(
            HerdrCoreTerminalRecord.self,
            from: try JSONEncoder().encode(
                JSONValue.object([
                    "address": .string("t1"), "cwd": .string("\(home)/user/projects/agy"), "state": .string("live"),
                    "argv": .array(foreground), "keep": .bool(true), "title": .string(""), "cols": .number(80),
                    "rows": .number(24), "name": .null, "reason": .null, "pid": .number(Double(row.pid)),
                    "labels": .object([:]),
                    "foreground": .object([
                        "pid": .number(Double(row.pid)), "name": name, "argv": .array(foreground),
                        "cwd": .string("\(home)/user/projects/agy"),
                    ]),
                ])))
        return (table, record)
    }

    private nonisolated static func agyBinder(_ table: ScriptedProcessTable, files: VirtualHostFiles) -> HerdrCoreSessionBinder {
        HerdrCoreSessionBinder(
            program: .agy, processes: { try await table.read($0) }, files: files.hostFiles(), clearLabels: { _ in })
    }

    /// Each scene and what it says: the conversation its lock names, none yet before
    /// the first prompt of a bare `agy`, and cannot tell for a second agy on a
    /// conversation already open.
    private nonisolated static let agyScenes: [(scene: String, evidence: ChatSessionEvidence)] = [
        (
            "after-first-prompt",
            .bound(
                sessionID: "00000000-0000-4000-8000-000000000103", transcriptRoot: "\(home)/.gemini/antigravity-cli",
                directory: nil)
        ),
        (
            "follow-after-fork",
            .bound(
                sessionID: "00000000-0000-4000-8000-000000000105", transcriptRoot: "\(home)/.gemini/antigravity-cli",
                directory: nil)
        ),
        ("at-prompt", .unavailable(.noConversationYet(.agy))),
        ("second-instance", cannotTell(.agy)),
    ]

    @Test(arguments: agyScenes)
    func antigravityBindsFromTheLockItHolds(_ entry: (scene: String, evidence: ChatSessionEvidence)) async throws {
        let (table, record) = try await Self.agyRig(entry.scene)
        let files = VirtualHostFiles(home: Self.home)

        let evidence = try await Self.agyBinder(table, files: files).check(record)

        #expect(evidence == entry.evidence)
        #expect(await table.requests.count == 1)
        #expect(await files.reads.isEmpty)
    }

    /// The Linux run of 2026-11-09 (`core-color-C12-fds`): a second agy on a
    /// conversation another agy held, past the about 30 s it held that conversation's
    /// database, held only its log and its crash log, which is all a new agy holds at
    /// its prompt there. Only the core's record of its argv tells the two apart, so
    /// any argument after `agy` cannot tell, and a bare `agy` has no conversation yet.
    @Test(arguments: [
        (["agy", "--conversation", "df829e0c-22c5-4585-bfba-b2762d0fa576"], cannotTell(.agy)),
        (["agy", "--conversation=df829e0c-22c5-4585-bfba-b2762d0fa576"], cannotTell(.agy)),
        (["agy", "-c"], cannotTell(.agy)),
        (["agy"], ChatSessionEvidence.unavailable(.noConversationYet(.agy))),
    ])
    func aSecondAntigravityCLIThatLetItsFilesGoTellsOnlyByItsArgv(
        _ argv: [String], _ expected: ChatSessionEvidence
    ) async throws {
        let (table, record) = try await Self.agyRig(
            "second-instance",
            files: [
                "\(Self.home)/.gemini/antigravity-cli/log/cli-20261108_202934.log",
                "\(Self.home)/.gemini/antigravity-cli/crashes/crash_390749_cd22135a-fc13-4b8c-ad3a-42f16b60f602.log",
                "/proc/390749", "/proc/390749/smaps", "/proc/390749/maps",
            ],
            argv: argv)

        #expect(try await Self.agyBinder(table, files: VirtualHostFiles(home: Self.home)).check(record) == expected)
    }

    // MARK: Heeler's launch of agy

    /// The Linux run of 2026-11-10 (`coreA-R13-newagent`): New Agent's `agy` on
    /// herdr-core 0.1.18, first listed with no foreground while bash read its startup
    /// files, then as `agy` under the same pid once its `exec` ran.
    private nonisolated static let launch = ["/bin/bash", "-ic", "exec \"$@\"", "/bin/bash", "agy"]
    private nonisolated static let launchPid = 2_637_998
    private nonisolated static let agyLog = "\(home)/.gemini/antigravity-cli/log/cli-20261110_063048.log"
    private nonisolated static let heldLock =
        "\(home)/.gemini/antigravity-cli/presence/00000000-0000-4000-8000-000000000103.lock"

    /// One process of the Terminal: its own when `parent` is the hold's.
    private nonisolated static func launchProcess(
        _ name: String, pid: Int = launchPid, parent: Int = 2_605_333, files: [String] = []
    ) -> ScriptedProcessTable.Process {
        ScriptedProcessTable.Process(
            pid: pid, parent: parent, name: name, start: "8001",
            environment: ["HC_SCOPE": "t8-scope", "HOME": home], openFiles: files)
    }

    /// The core's record of the Terminal: `argv` as started, and its foreground as
    /// sampled, or none yet.
    private nonisolated static func launchRecord(
        argv: [String] = launch, foreground: (name: String, argv: [String])?
    ) throws -> HerdrCoreTerminalRecord {
        var fields: [String: JSONValue] = [
            "address": .string("t8"), "cwd": .string("\(home)/heeler-fix/proj-core"), "state": .string("live"),
            "argv": .array(argv.map(JSONValue.string)), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .string("agy-2"), "reason": .null,
            "pid": .number(Double(launchPid)), "labels": .object([:]),
        ]
        if let foreground {
            fields["foreground"] = .object([
                "pid": .number(Double(launchPid)), "name": .string(foreground.name),
                "argv": .array(foreground.argv.map(JSONValue.string)),
                "cwd": .string("\(home)/heeler-fix/proj-core"),
            ])
        }
        return try JSONDecoder().decode(HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(JSONValue.object(fields)))
    }

    private nonisolated static func launchCheck(
        _ processes: [ScriptedProcessTable.Process], record: HerdrCoreTerminalRecord
    ) async throws -> ChatSessionEvidence {
        let table = ScriptedProcessTable()
        for process in processes { await table.add(process) }
        let files = VirtualHostFiles(home: home)
        let evidence = try await agyBinder(table, files: files).check(record)
        #expect(await table.requests.count <= 1)
        #expect(await files.reads.isEmpty)
        return evidence
    }

    /// Until the core samples the program it became, Heeler's launch reads as still
    /// starting, not as can't tell: the shell reading its startup files, sampled or
    /// not, and the `agy` its `exec` made of it before the first sample. A lock that
    /// agy already holds binds as ever.
    @Test func heelersLaunchOfAntigravityCLIReadsAsStartingUntilTheCoreSamplesIt() async throws {
        let unsampled = try Self.launchRecord(foreground: nil)
        let sampledShell = try Self.launchRecord(foreground: ("bash", Self.launch))
        let shell = Self.launchProcess("bash")
        #expect(try await Self.launchCheck([shell], record: unsampled) == .launching)
        #expect(try await Self.launchCheck([shell], record: sampledShell) == .launching)
        let atPrompt = Self.launchProcess("agy", files: [Self.agyLog])
        #expect(try await Self.launchCheck([atPrompt], record: unsampled) == .launching)
        #expect(try await Self.launchCheck([atPrompt], record: sampledShell) == .launching)

        let locked = Self.launchProcess("agy", files: [Self.agyLog, Self.heldLock])
        #expect(
            try await Self.launchCheck([locked], record: unsampled)
                == .bound(
                    sessionID: "00000000-0000-4000-8000-000000000103",
                    transcriptRoot: "\(Self.home)/.gemini/antigravity-cli", directory: nil))
        #expect(
            try await Self.launchCheck([atPrompt], record: Self.launchRecord(foreground: ("agy", ["agy"])))
                == .unavailable(.noConversationYet(.agy)))
    }

    /// What ADR 0034 keeps at can't tell still reads so under Heeler's launch: a
    /// shell left in the Terminal, as a restart leaves the core's own, a launcher in
    /// front of agy whatever it goes by, a second `agy` under the launch's shell, a
    /// launch with arguments, and an agy holding a conversation's database without
    /// its lock, as a second agy on an open conversation does.
    @Test func whatCannotTellStillCannotUnderHeelersLaunch() async throws {
        let shell = Self.launchProcess("bash")
        let restarted = try Self.launchRecord(argv: ["/bin/bash"], foreground: ("bash", ["/bin/bash"]))
        #expect(try await Self.launchCheck([shell], record: restarted) == Self.cannotTell(.agy))
        let shellInFront = try Self.launchRecord(foreground: ("bash", ["/bin/bash"]))
        #expect(try await Self.launchCheck([shell], record: shellInFront) == Self.cannotTell(.agy))

        let unsampled = try Self.launchRecord(foreground: nil)
        let child = Self.launchProcess("agy", pid: Self.launchPid + 1, parent: Self.launchPid, files: [Self.agyLog])
        for front in ["agy", "mise", "bash"] {
            #expect(
                try await Self.launchCheck([Self.launchProcess(front), child], record: unsampled)
                    == Self.cannotTell(.agy), "\(front)")
        }

        let resumed = Self.launch + ["--conversation", "00000000-0000-4000-8000-000000000102"]
        #expect(
            try await Self.launchCheck([shell], record: Self.launchRecord(argv: resumed, foreground: nil))
                == Self.cannotTell(.agy))
        let database = "\(Self.home)/.gemini/antigravity-cli/conversations/00000000-0000-4000-8000-000000000102.db"
        #expect(
            try await Self.launchCheck([Self.launchProcess("agy", files: [Self.agyLog, database])], record: unsampled)
                == Self.cannotTell(.agy))
    }
}
