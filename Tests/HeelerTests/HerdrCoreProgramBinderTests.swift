import Foundation
import Testing

@testable import Heeler

/// Binding Codex, Grok Build, OpenCode and Antigravity CLI from what a Host shows
/// (ADR 0034). The
/// process rows and files are the recordings in `ChatFixtures/host-evidence`,
/// which never saw a signed-in account. They scrubbed everything from a process's
/// environment but its scope, so each test adds the home variable its recording's
/// paths show. An edit to a recording is said so at the test.
@Suite("herdr-core program binder")
struct HerdrCoreProgramBinderTests {
    private actor LabelLog {
        var cleared: [[String]] = []
        func clear(_ names: [String]) { cleared.append(names) }
    }

    private struct Rig {
        let program: ChatProgram
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/user")
        let labels = LabelLog()

        var binder: HerdrCoreSessionBinder {
            let table = table
            let labels = labels
            return HerdrCoreSessionBinder(
                program: program,
                processes: { try await table.read($0) },
                files: files.hostFiles(),
                clearLabels: { await labels.clear($0.keys.sorted()) })
        }

        func add(_ rows: [HostEvidenceFixture.Row], environment: [String: String] = [:]) async {
            for row in rows {
                var process = row.process
                process.environment.merge(environment) { $1 }
                await table.add(process)
            }
        }

        func write(_ files: [String: String]?) async {
            for (path, text) in files ?? [:] {
                await self.files.write(Data(text.utf8), at: path)
            }
        }

        var reads: [String] {
            get async { await files.reads.map(\.path) }
        }

        var cleared: [[String]] {
            get async { await labels.cleared }
        }
    }

    private static func record(
        pid: Int, foreground: Int? = nil, argv: [String], name: String = "agent", labels: [String: String] = [:]
    ) throws -> HerdrCoreTerminalRecord {
        let value = JSONValue.object([
            "address": .string("t7"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array(argv.map(JSONValue.string)), "keep": .bool(true), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null, "pid": .number(Double(pid)), "reason": .null,
            "labels": .object(labels.mapValues(JSONValue.string)),
            "foreground": .object([
                "pid": .number(Double(foreground ?? pid)), "name": .string(name),
                "argv": .array(argv.map(JSONValue.string)), "cwd": .string("/work/app"),
            ]),
        ])
        return try JSONDecoder().decode(HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(value))
    }

    private static func record(
        for row: HostEvidenceFixture.Row, labels: [String: String] = [:]
    ) throws -> HerdrCoreTerminalRecord {
        try record(pid: row.pid, argv: row.argv, name: row.name, labels: labels)
    }

    private static func firstRow(_ scene: HostEvidenceFixture.Scene) throws -> HostEvidenceFixture.Row {
        try #require(scene.processes?.first)
    }

    // MARK: Codex

    private static let codexHome = "/home/user/lab/iso/codex/codex-home"
    private static let firstThread = "01900000-0000-7000-8000-000000000001"
    private static let secondThread = "01900000-0000-7000-8000-000000000002"

    private static func rollout(thread: String = firstThread, home: String = codexHome) -> String {
        "\(home)/sessions/2026/11/01/rollout-2026-11-01T07-29-06-\(thread).jsonl"
    }

    /// A Codex holding these lines, on a recording's process tree.
    private static func codexRig(holding files: [String: String]) async throws -> (Rig, HerdrCoreTerminalRecord) {
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("after-first-reply")
        let rows = try #require(scene.processes)
        let rig = Rig(program: .codex)
        await rig.add(rows, environment: ["CODEX_HOME": codexHome])
        var native = try #require(rows.last).process
        native.environment["CODEX_HOME"] = codexHome
        native.openFiles = Array(files.keys).sorted()
        await rig.table.add(native)
        await rig.write(files)
        return (rig, try record(for: try firstRow(scene)))
    }

    @Test func aNoDaemonCodexBindsTheRootThreadOfTheRolloutItHolds() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("after-first-reply")
        let rig = Rig(program: .codex)
        await rig.add(try #require(scene.processes), environment: ["CODEX_HOME": Self.codexHome])
        await rig.write(scene.files)

        let evidence = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        #expect(
            evidence == .bound(
                sessionID: Self.firstThread, transcriptRoot: Self.codexHome,
                directory: "/home/user/lab/iso/projects/codex"))
        #expect(await rig.table.requests.count == 1)
        #expect(await rig.reads == [Self.rollout()])
    }

    /// The rollout comes with the first prompt, and until then Codex holds only a
    /// lock, which names a thread that has no conversation to read yet.
    @Test func atItsPromptACodexHoldsNoRolloutAndSaysSo() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("at-prompt")
        let rig = Rig(program: .codex)
        await rig.add(try #require(scene.processes), environment: ["CODEX_HOME": Self.codexHome])

        let evidence = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        #expect(evidence == .unavailable(.cannotTellSession(.codex)))
        #expect(await rig.reads.isEmpty)
        #expect(await rig.files.statuses.isEmpty)
    }

    @Test func aSubagentBesideTheRootBindsTheRoot() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon-subagent").scene("root-and-subagent")
        let home = "/home/user/lab/iso/codexs/codex-home"
        let rig = Rig(program: .codex)
        await rig.add(try #require(scene.processes), environment: ["CODEX_HOME": home])
        await rig.write(scene.files)

        let evidence = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        guard case .bound(let session, let root, _) = evidence else {
            Issue.record("Expected a binding, got \(evidence)")
            return
        }
        #expect(session == Self.firstThread)
        #expect(root == home)
    }

    private static let afterNewHome = "/home/user/lab/iso/codexn/codex-home"

    private static func afterNewEvidence(holding files: (HostEvidenceFixture.Scene) throws -> [String])
        async throws -> ChatSessionEvidence
    {
        let fixture = try HostEvidenceFixture.named("codex/no-daemon-after-new")
        let scene = try fixture.scene("before-new")
        let rig = Rig(program: .codex)
        let pid = try #require(scene.agentProcess)
        await rig.table.add(
            ScriptedProcessTable.Process(
                pid: pid, name: "codex", start: "1",
                environment: ["HC_SCOPE": "scope", "CODEX_HOME": afterNewHome], openFiles: try files(scene)))
        await rig.write(fixture.files)
        return try await rig.binder.check(try record(pid: pid, argv: ["codex", "--no-daemon"]))
    }

    @Test func twoRootsAfterNewBindNothing() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon-after-new").scene("after-new-and-a-prompt")
        let held = try #require(scene.heldByAgentProcess)

        let evidence = try await Self.afterNewEvidence { _ in held }

        #expect(evidence == .unavailable(.cannotTellSession(.codex)))
    }

    /// The same process before `/new`, in the same recording, binds its one root.
    @Test func theSameProcessBeforeNewBindsItsOneRoot() async throws {
        let evidence = try await Self.afterNewEvidence { try #require($0.heldByAgentProcess) }

        guard case .bound(let session, _, _) = evidence else {
            Issue.record("Expected a binding, got \(evidence)")
            return
        }
        #expect(session == Self.firstThread)
    }

    /// The recording's `observed`, which no scene holds: a prompt right after `/new`
    /// leaves the new thread's lock and no rollout, so the screen is on a thread with
    /// nothing to read while the old rollout is still the one held. This edits
    /// `before-new` to that, with the old lock kept and let go, since "only the new
    /// thread's lock" does not say which.
    @Test(arguments: [true, false])
    func aNewThreadsLockBeforeItsRolloutBindsNothing(keepingTheOldLock: Bool) async throws {
        let newLock = "\(Self.afterNewHome)/thread-writer-locks/\(Self.secondThread).lock"

        let evidence = try await Self.afterNewEvidence { scene in
            let held = try #require(scene.heldByAgentProcess)
            return (keepingTheOldLock ? held : held.filter { !$0.hasSuffix(".lock") }) + [newLock]
        }

        #expect(evidence == .unavailable(.cannotTellSession(.codex)))
    }

    /// Written for the test: a lock in a name Codex is not recorded using could be
    /// any thread's.
    @Test func aLockInAnUnknownNameBindsNothing() async throws {
        let (rig, record) = try await Self.codexRig(holding: [
            Self.rollout(): Self.meta(),
            "\(Self.codexHome)/thread-writer-locks/\(Self.firstThread).lock": "",
            "\(Self.codexHome)/thread-writer-locks/writer.lock": "",
        ])

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.codex)))
    }

    private static func meta(thread: String = firstThread, fields: String = #""source":"cli""#) -> String {
        #"{"type":"session_meta","payload":{"id":"\#(thread)",\#(fields),"cwd":"/w"}}"# + "\n"
    }

    private static let subagentFields = #""parent_thread_id":"x","thread_source":"subagent","source":{"subagent":{}}"#

    /// Written for the test: a rollout's first line in each shape that names no one
    /// root, each of which must leave Chat saying so rather than guessing.
    @Test(arguments: [
        ("only a subagent", meta(fields: subagentFields)),
        ("a source that is no word", meta(fields: #""source":{"mcp":{}}"#)),
        ("a parent and no other sign", meta(fields: #""parent_thread_id":"x","source":"cli""#)),
        ("a subagent's thread source", meta(fields: #""thread_source":"subagent","source":"cli""#)),
        ("another thread's meta", meta(thread: secondThread)),
        ("another record first", #"{"type":"response_item","payload":{"id":"\#(firstThread)"}}"# + "\n"),
        ("no end to the line yet", #"{"type":"session_meta","payload":{"id":"\#(firstThread)""#),
        ("no line at all", ""),
    ])
    func aRolloutWithoutOneRootBindsNothing(_ what: String, _ head: String) async throws {
        let (rig, record) = try await Self.codexRig(holding: [Self.rollout(): head])

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.codex)), "\(what)")
    }

    @Test func aRolloutBeingWrittenBesideARootBindsNothing() async throws {
        let (rig, record) = try await Self.codexRig(holding: [
            Self.rollout(): Self.meta(),
            Self.rollout(thread: Self.secondThread): #"{"type":"session_"#,
        ])

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.codex)))
    }

    @Test func tooManyHeldRolloutsReadNothing() async throws {
        var files: [String: String] = [:]
        for index in 0...HerdrCoreSessionBinder.heldRolloutLimit {
            let thread = "01900000-0000-7000-8000-00000000000\(index)"
            files[Self.rollout(thread: thread)] = Self.meta(thread: thread)
        }
        let (rig, record) = try await Self.codexRig(holding: files)

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.codex)))
        #expect(await rig.reads.isEmpty)
    }

    /// A hold whose path is not a rollout's says nothing: the recording's lock, a
    /// compressed segment, a deleted file, and a name outside the sessions folders.
    @Test func onlyARolloutCounts() async throws {
        let (rig, record) = try await Self.codexRig(holding: [
            "\(Self.codexHome)/thread-writer-locks/\(Self.firstThread).lock": "",
            Self.rollout() + ".zst": "",
            Self.rollout() + " (deleted)": "",
            "/tmp/rollout-2026-11-01T07-29-06-\(Self.firstThread).jsonl": Self.meta(),
        ])

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.codex)))
        #expect(await rig.reads.isEmpty)
    }

    @Test func anArchivedRolloutStillCounts() async throws {
        let path = "\(Self.codexHome)/archived_sessions/rollout-2026-11-01T07-29-06-\(Self.firstThread).jsonl"
        let (rig, record) = try await Self.codexRig(holding: [path: Self.meta()])

        #expect(try await rig.binder.check(record) == .bound(
            sessionID: Self.firstThread, transcriptRoot: Self.codexHome, directory: "/w"))
    }

    @Test func aCodexWithNoHomeVariableLooksUnderItsOwnHome() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("after-first-reply")
        let rig = Rig(program: .codex)
        await rig.add(try #require(scene.processes), environment: ["HOME": "/home/other"])
        await rig.write(scene.files)

        let evidence = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        guard case .bound(_, let root, _) = evidence else {
            Issue.record("Expected a binding, got \(evidence)")
            return
        }
        #expect(root == "/home/other/.codex")
    }

    @Test func aCodexWhoseEnvironmentCannotBeReadBindsNothing() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("after-first-reply")
        let rig = Rig(program: .codex)
        await rig.add(try #require(scene.processes))
        await rig.write(scene.files)

        // Neither home variable: the recording's rows carry only the scope.
        #expect(
            try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))
                == .unavailable(.cannotTellSession(.codex)))
    }

    /// The first Terminal's walk meets the daemon, with the Terminal's scope, the
    /// same name, and every rollout. The rollouts are none of this Agent's to read.
    @Test func theWalkSkipsTheManagedDaemonAndSaysToReopen() async throws {
        let scene = try HostEvidenceFixture.named("codex/default-daemon").scene("first-terminal")
        let rows = try #require(scene.processes)
        let daemon = try #require(rows.first { $0.argv.contains("--managed-daemon") })
        let terminal = try Self.firstRow(scene)
        #expect(daemon.environment["HC_SCOPE"] == terminal.environment["HC_SCOPE"])
        #expect(!daemon.files.isEmpty)
        let home = "/home/user/lab/iso/codexd/codex-home"
        let rig = Rig(program: .codex)
        await rig.add(rows, environment: ["CODEX_HOME": home])
        await rig.write(scene.files)

        let evidence = try await rig.binder.check(try Self.record(for: terminal))

        #expect(evidence == .unavailable(.codexSharedDaemon))
        #expect(await rig.reads.isEmpty)
    }

    /// A second Terminal has no daemon under it and holds nothing. Its launch and
    /// the control socket say it runs on the shared one, as Herdr TUI's check does.
    /// The recording did not list the socket: its path is from Codex 0.164.0's
    /// source (`CodexLaunch`).
    @Test func aCodexJoiningTheDaemonFromAnotherTerminalSaysToReopen() async throws {
        let scene = try HostEvidenceFixture.named("codex/default-daemon").scene("second-terminal-joined")
        let rows = try #require(scene.secondTerminal)
        let home = "/home/user/lab/iso/codexd/codex-home"
        let rig = Rig(program: .codex)
        await rig.add(rows, environment: ["CODEX_HOME": home])
        await rig.files.write(Data(), at: "\(home)/app-server-control/app-server-control.sock")

        let evidence = try await rig.binder.check(try Self.record(for: try #require(rows.first)))

        #expect(evidence == .unavailable(.codexSharedDaemon))
    }

    /// A second default Codex's process tree, with `foreground` as the words of the
    /// process that started it. The daemon's socket exists. The rows are the
    /// recording's, and the wrappers around them are the forms the Agent rule's
    /// vectors read as Codex (herdr compatibility).
    private static func joiningCodex(
        foreground argv: [String], holds files: [String] = []
    ) async throws -> (Rig, HerdrCoreTerminalRecord) {
        let scene = try HostEvidenceFixture.named("codex/default-daemon").scene("second-terminal-joined")
        let rows = try #require(scene.secondTerminal)
        let home = "/home/user/lab/iso/codexd/codex-home"
        let rig = Rig(program: .codex)
        await rig.add(rows, environment: ["CODEX_HOME": home])
        var native = try #require(rows.last).process
        native.environment["CODEX_HOME"] = home
        native.openFiles = files
        await rig.table.add(native)
        await rig.files.write(Data(), at: "\(home)/app-server-control/app-server-control.sock")
        return (rig, try record(pid: try #require(rows.first).pid, argv: argv, name: "sh"))
    }

    private nonisolated static let fishWrapper = [
        "/usr/bin/fish", "-ic", "command $argv[2..]; exec $argv[1] -i", "/usr/bin/fish",
    ]

    /// A Template's `sh -c` line stays the foreground on Debian, as the desktop app's
    /// fish wrapper does, and the Console calls each of these Codex.
    @Test(arguments: [
        ["/bin/sh", "-c", "codex"],
        fishWrapper + ["codex"],
        ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"],
        ["/bin/sh", "/home/user/bin/codex.sh"],
    ])
    func aCodexJoiningTheDaemonBehindAWrapperGetsOnlyTheMessage(foreground: [String]) async throws {
        let (rig, record) = try await Self.joiningCodex(foreground: foreground)

        #expect(try await rig.binder.check(record) == .unavailable(.codexSharedDaemon))
        #expect(try await rig.binder.candidates(of: record) == .sharedDaemon)
    }

    /// Codex's own arguments still keep it off the daemon behind a wrapper, and a
    /// subcommand with no terminal UI says nothing about it.
    @Test(arguments: [
        ["/bin/sh", "-c", "codex --no-daemon"],
        ["/bin/sh", "-c", "cd /work/app && exec codex --no-daemon"],
        fishWrapper + ["codex", "--no-daemon"],
        ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js", "--no-daemon"],
        ["/bin/sh", "-c", "codex exec hello"],
    ])
    func aCodexBehindAWrapperThatKeepsOffTheDaemonIsNotToldToReopen(foreground: [String]) async throws {
        let (rig, record) = try await Self.joiningCodex(foreground: foreground)

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.codex)))
    }

    /// A script's arguments are not Codex's, so `--no-daemon` inside it does not show.
    /// Its native child's thread-writer lock does (`codex/no-daemon` at its prompt).
    @Test func aThreadLockSaysAScriptsCodexIsNotOnTheDaemon() async throws {
        let (rig, record) = try await Self.joiningCodex(
            foreground: ["/bin/sh", "/home/user/bin/codex.sh"],
            holds: ["/home/user/lab/iso/codexd/codex-home/thread-writer-locks/\(Self.firstThread).lock"])

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.codex)))
    }

    @Test func withNoSocketThatCodexIsNotOnTheDaemon() async throws {
        let scene = try HostEvidenceFixture.named("codex/default-daemon").scene("second-terminal-joined")
        let rows = try #require(scene.secondTerminal)
        let rig = Rig(program: .codex)
        await rig.add(rows, environment: ["CODEX_HOME": "/home/user/lab/iso/codexd/codex-home"])

        let evidence = try await rig.binder.check(try Self.record(for: try #require(rows.first)))

        #expect(evidence == .unavailable(.cannotTellSession(.codex)))
    }

    /// A no-daemon Codex at its prompt beside a running daemon keeps off it.
    @Test func aNoDaemonCodexBesideARunningDaemonIsNotToldToReopen() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("at-prompt")
        let rig = Rig(program: .codex)
        await rig.add(try #require(scene.processes), environment: ["CODEX_HOME": Self.codexHome])
        await rig.files.write(Data(), at: "\(Self.codexHome)/app-server-control/app-server-control.sock")

        let evidence = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        #expect(evidence == .unavailable(.cannotTellSession(.codex)))
    }

    /// A native Codex with nothing above it (the 0.166 observation), whose daemon
    /// sits right under the foreground.
    @Test func theDaemonIsSkippedUnderANativeForegroundToo() async throws {
        let scene = try HostEvidenceFixture.named("codex/default-daemon").scene("first-terminal")
        let rows = try #require(scene.processes).dropFirst().map { row -> HostEvidenceFixture.Row in
            var row = row
            if row.pid == 4367 { row.parent = 1 }
            return row
        }
        let rig = Rig(program: .codex)
        await rig.add(Array(rows), environment: ["CODEX_HOME": "/home/user/lab/iso/codexd/codex-home"])

        let evidence = try await rig.binder.check(try Self.record(for: try #require(rows.first)))

        #expect(evidence == .unavailable(.codexSharedDaemon))
    }

    /// The recording's daemon sits under the native Codex, nearer ones winning the
    /// walk anyway. This edit moves it beside the native Codex, where only the skip
    /// keeps it from reading as a second Agent as near, which would tell nothing.
    @Test func aDaemonBesideTheAgentIsNoSecondAgent() async throws {
        let scene = try HostEvidenceFixture.named("codex/default-daemon").scene("first-terminal")
        let rows = try #require(scene.processes).map { row -> HostEvidenceFixture.Row in
            var row = row
            if row.pid == 4397 || row.pid == 4465 { row.parent = 4357 }
            return row
        }
        let rig = Rig(program: .codex)
        await rig.add(rows, environment: ["CODEX_HOME": "/home/user/lab/iso/codexd/codex-home"])

        let evidence = try await rig.binder.check(try Self.record(for: try #require(rows.first)))

        #expect(evidence == .unavailable(.codexSharedDaemon))
        #expect(await rig.reads.isEmpty)
    }

    /// The daemon's update loop has no `--managed-daemon` and holds nothing. Beside
    /// a Codex with its own rollout (an edit of the recording) it does not stop the
    /// bind.
    @Test func theUpdateLoopBesideACodexHoldingItsRolloutDoesNotStopTheBind() async throws {
        let loop = try #require(
            try HostEvidenceFixture.named("codex/default-daemon").scene("first-terminal").processes?
                .first { $0.argv.contains("pid-update-loop") })
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("after-first-reply")
        let rows = try #require(scene.processes)
        var besideNative = loop
        besideNative.pid = 900_001
        besideNative.parent = try Self.firstRow(scene).pid
        besideNative.environment["HC_SCOPE"] = try Self.firstRow(scene).environment["HC_SCOPE"]
        let rig = Rig(program: .codex)
        await rig.add(rows + [besideNative], environment: ["CODEX_HOME": Self.codexHome])
        await rig.write(scene.files)

        let evidence = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        #expect(
            evidence == .bound(
                sessionID: Self.firstThread, transcriptRoot: Self.codexHome,
                directory: "/home/user/lab/iso/projects/codex"))
    }

    @Test func theCheckAsksOnlyWhatItNames() async throws {
        let scene = try HostEvidenceFixture.named("codex/no-daemon").scene("at-prompt")
        let rig = Rig(program: .codex)
        await rig.add(try #require(scene.processes), environment: ["CODEX_HOME": Self.codexHome])

        _ = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        let request = try #require(await rig.table.requests.first)
        #expect(Set(request.valuesOf) == ["HC_SCOPE", "HOME", "CODEX_HOME"])
        #expect(request.namesOf.isEmpty && request.namesWithPrefix.isEmpty)
        #expect(request.readsOpenFiles)
        #expect(Set(request.argumentsAmong) == ["--managed-daemon", "app-server", "pid-update-loop"])
    }

    @Test func theReopenMessageNamesTheCommand() {
        let reason = ChatUnavailableReason.codexSharedDaemon
        let explanation = reason.explanation.replacingOccurrences(of: "\u{2011}", with: "-")
        #expect(explanation.contains("codex resume --no-daemon"))
        #expect(explanation.contains("Codex's list"))
        // The daemon can outlive the TUI and keep the thread (hc-lab, D4).
        #expect(explanation.contains("codex app-server daemon stop"))
        #expect(reason.offersRetry)
    }

    // MARK: Grok Build

    private static let grokHome = "/home/user/lab/iso/grok/grok-home"
    private static let grokSession = "00000000-0000-4000-8000-000000000001"

    private static func grokRig() async throws -> (Rig, HostEvidenceFixture, HostEvidenceFixture.Row) {
        let fixture = try HostEvidenceFixture.named("grok/s-flag")
        let scene = try fixture.scene("one-terminal")
        let rig = Rig(program: .grok)
        await rig.add(try #require(scene.processes), environment: ["GROK_HOME": grokHome])
        return (rig, fixture, try firstRow(scene))
    }

    @Test func aGrokBuildBindsFromTheOneRowThatMatches() async throws {
        let (rig, fixture, row) = try await Self.grokRig()
        await rig.write(try fixture.scene("one-terminal").files)

        let evidence = try await rig.binder.check(try Self.record(for: row))

        #expect(
            evidence == .bound(
                sessionID: Self.grokSession, transcriptRoot: Self.grokHome,
                directory: "/home/user/lab/iso/projects/grok"))
        #expect(await rig.table.requests.count == 1)
        #expect(await rig.reads == ["\(Self.grokHome)/active_sessions.json"])
    }

    @Test func anotherTerminalsRowDoesNotCount() async throws {
        let (rig, fixture, row) = try await Self.grokRig()
        await rig.write(try fixture.scene("second-terminal").files)

        let evidence = try await rig.binder.check(try Self.record(for: row))

        guard case .bound(let session, _, _) = evidence else {
            Issue.record("Expected a binding, got \(evidence)")
            return
        }
        #expect(session == Self.grokSession)
    }

    @Test func twoMatchingRowsAfterNewBindNothing() async throws {
        let (rig, fixture, row) = try await Self.grokRig()
        await rig.write(try fixture.scene("after-new-in-first-terminal").files)

        #expect(
            try await rig.binder.check(try Self.record(for: row)) == .unavailable(.cannotTellSession(.grok)))
    }

    /// The row names the Terminal's process while a leader, of another name, holds
    /// the session's files.
    @Test func aLeaderUnderGrokBuildChangesNothing() async throws {
        let scene = try HostEvidenceFixture.named("grok/s-flag").scene("leader-mode")
        let home = "/home/user/lab/iso/grok/grok-home-leader"
        let rig = Rig(program: .grok)
        await rig.add(try #require(scene.processes), environment: ["GROK_HOME": home])
        await rig.write(scene.files)

        let evidence = try await rig.binder.check(try Self.record(for: try Self.firstRow(scene)))

        guard case .bound(let session, let root, _) = evidence else {
            Issue.record("Expected a binding, got \(evidence)")
            return
        }
        #expect(session == "00000000-0000-4000-8000-000000000004")
        #expect(root == home)
    }

    /// Edits of the recording's row, each in a way that must not match.
    @Test(arguments: [
        ("another start", #""pid_start": 127528"#, #""pid": 5579"#),
        ("another pid", #""pid_start": 127527"#, #""pid": 5580"#),
        ("the start as text", #""pid_start": "127527""#, #""pid": 5579"#),
        ("the start as a fraction", #""pid_start": 127527.5"#, #""pid": 5579"#),
    ])
    func aRowThatDoesNotMatchBindsNothing(_ what: String, _ start: String, _ pid: String) async throws {
        let (rig, fixture, row) = try await Self.grokRig()
        let path = "\(Self.grokHome)/active_sessions.json"
        let text = try #require(try fixture.scene("one-terminal").files?[path])
            .replacingOccurrences(of: #""pid_start": 127527"#, with: start)
            .replacingOccurrences(of: #""pid": 5579"#, with: pid)
        await rig.write([path: text])

        #expect(
            try await rig.binder.check(try Self.record(for: row)) == .unavailable(.cannotTellSession(.grok)),
            "\(what)")
    }

    @Test(arguments: [
        ("no rows", "[]"), ("half a file", #"[{"session_id":"#), ("an id that is no UUID", #"[{"session_id":"x","pid":5579,"pid_start":127527}]"#),
    ])
    func anUnusableFileBindsNothing(_ what: String, _ text: String) async throws {
        let (rig, _, row) = try await Self.grokRig()
        await rig.write(["\(Self.grokHome)/active_sessions.json": text])

        #expect(
            try await rig.binder.check(try Self.record(for: row)) == .unavailable(.cannotTellSession(.grok)),
            "\(what)")
    }

    @Test func noFileBindsNothing() async throws {
        let (rig, _, row) = try await Self.grokRig()

        #expect(
            try await rig.binder.check(try Self.record(for: row)) == .unavailable(.cannotTellSession(.grok)))
    }

    @Test func grokHomeComesFromTheAgentAndElseItsHome() async throws {
        let fixture = try HostEvidenceFixture.named("grok/s-flag")
        let scene = try fixture.scene("one-terminal")
        let row = try Self.firstRow(scene)
        let rig = Rig(program: .grok)
        await rig.add([row], environment: ["HOME": "/home/other"])
        let text = try #require(scene.files?["\(Self.grokHome)/active_sessions.json"])
        await rig.write(["/home/other/.grok/active_sessions.json": text])

        let evidence = try await rig.binder.check(try Self.record(for: row))

        guard case .bound(_, let root, _) = evidence else {
            Issue.record("Expected a binding, got \(evidence)")
            return
        }
        #expect(root == "/home/other/.grok")
    }

    // MARK: OpenCode

    private static let launchID = "ses_e6a000000001Abcdefghijklmn"
    private static let otherID = "ses_e6a000000002Abcdefghijklmn"
    private static let openCodeLabel = HerdrCoreLaunch.sessionHintLabel

    private static func openCodeRig(
        _ fixture: String = "opencode/ses-flag-2.2.5"
    ) async throws -> (Rig, HostEvidenceFixture.Row) {
        let scene = try HostEvidenceFixture.named(fixture).scene("first-terminal")
        let rig = Rig(program: .opencode)
        await rig.add(try #require(scene.processes))
        return (rig, try firstRow(scene))
    }

    @Test(arguments: ["opencode/ses-flag-2.2.5", "opencode/ses-flag-2.0.32"])
    func anOpenCodeBindsFromTheIDItWasStartedWith(_ fixture: String) async throws {
        let (rig, row) = try await Self.openCodeRig(fixture)
        let launch = try #require(try HostEvidenceFixture.named(fixture).launchIds?["terminalA"])
        #expect(row.argv.suffix(2) == ["-s", launch])

        let evidence = try await rig.binder.check(
            try Self.record(for: row, labels: [Self.openCodeLabel: launch]))

        #expect(evidence == .bound(sessionID: launch, transcriptRoot: nil, directory: nil))
        #expect(await rig.table.requests.count == 1)
        #expect(await rig.reads.isEmpty)
    }

    /// The whole launch's request, so this can't drift from what a launch writes.
    @Test func whatALaunchWritesBinds() async throws {
        let request = HerdrCoreLaunch.agentRequest(
            kind: .opencode, name: nil, arguments: [], shell: "/bin/zsh", openCodeVersion: "opencode v2.2.5",
            placement: HerdrCoreLaunch.Placement(cwd: "/work/app"))
        let label = try #require(request["labels"]?[Self.openCodeLabel]?.stringValue)
        let (rig, row) = try await Self.openCodeRig()

        let evidence = try await rig.binder.check(
            try Self.record(pid: row.pid, argv: ["opencode", "-s", label], labels: [Self.openCodeLabel: label]))

        #expect(evidence == .bound(sessionID: label, transcriptRoot: nil, directory: nil))
    }

    /// An OpenCode older than 2.1 gets no flag and no label from a launch.
    @Test func anOlderOpenCodeCannotTell() async throws {
        let request = HerdrCoreLaunch.agentRequest(
            kind: .opencode, name: nil, arguments: [], shell: "/bin/zsh", openCodeVersion: "1.19.5",
            placement: HerdrCoreLaunch.Placement(cwd: "/work/app"))
        #expect(request["labels"]?[Self.openCodeLabel] == nil)
        let (rig, row) = try await Self.openCodeRig()

        let evidence = try await rig.binder.check(try Self.record(pid: row.pid, argv: ["opencode"]))

        #expect(evidence == .unavailable(.cannotTellSession(.opencode)))
    }

    @Test func anOpenCodeHeelerDidNotStartCannotTell() async throws {
        let (rig, row) = try await Self.openCodeRig()

        #expect(
            try await rig.binder.check(try Self.record(for: row))
                == .unavailable(.cannotTellSession(.opencode)))
    }

    /// A label only counts for the process that took that id: one left behind by a
    /// program that gave way to another says nothing.
    @Test(arguments: [
        ("no flag", ["opencode"]), ("another id", ["opencode", "-s", otherID]),
        ("the id and no flag", ["opencode", launchID]), ("another program", ["zsh", "-s", launchID]),
    ])
    func aLaunchLabelTheProcessDidNotTakeCannotTell(_ what: String, _ argv: [String]) async throws {
        let (rig, row) = try await Self.openCodeRig()
        var process = row.process
        process.name = argv[0]
        await rig.table.add(process)
        for child in [row.pid + 20] { await rig.table.remove(child) }

        let evidence = try await rig.binder.check(
            try Self.record(pid: row.pid, argv: argv, labels: [Self.openCodeLabel: Self.launchID]))

        #expect(evidence == .unavailable(.cannotTellSession(.opencode)), "\(what)")
    }

    @Test func aLabelThatIsNoSessionIDCannotTell() async throws {
        let (rig, row) = try await Self.openCodeRig()

        let evidence = try await rig.binder.check(
            try Self.record(pid: row.pid, argv: ["opencode", "-s", "nope"], labels: [Self.openCodeLabel: "nope"]))

        #expect(evidence == .unavailable(.cannotTellSession(.opencode)))
    }

    @Test func aHintForThisProcessBinds() async throws {
        let (rig, row) = try await Self.openCodeRig()
        let hint = #"{"session":"\#(Self.otherID)","pid":\#(row.pid),"start":"\#(row.start)"}"#

        let evidence = try await rig.binder.check(try Self.record(for: row, labels: ["heeler.session": hint]))

        #expect(evidence == .bound(sessionID: Self.otherID, transcriptRoot: nil, directory: nil))
        #expect(await rig.cleared.isEmpty)
    }

    @Test func aStaleHintIsClearedAndCannotTell() async throws {
        let (rig, row) = try await Self.openCodeRig()
        let hints = [
            #"{"session":"\#(Self.otherID)","pid":\#(row.pid),"start":"1"}"#,
            #"{"session":"\#(Self.otherID)","pid":1,"start":"\#(row.start)"}"#,
        ]
        for hint in hints {
            let evidence = try await rig.binder.check(try Self.record(for: row, labels: ["heeler.session": hint]))
            #expect(evidence == .unavailable(.cannotTellSession(.opencode)))
        }
        #expect(await rig.cleared == [["heeler.session"], ["heeler.session"]])
    }

    /// What the plugin writes: the hint names a process, and each new conversation
    /// is a new hint. An OpenCode started with no id has nothing else (ADR 0033).
    @Test(arguments: ["opencode/ses-flag-2.2.5", "opencode/ses-flag-2.0.32"])
    func thePluginsLabelBindsAndANewOneRebinds(_ fixture: String) async throws {
        let (rig, row) = try await Self.openCodeRig(fixture)
        func label(_ session: String) -> [String: String] {
            ["heeler.session": #"{"session":"\#(session)","pid":\#(row.pid),"start":"\#(row.start)"}"#]
        }
        let argv = ["opencode"]

        let first = try await rig.binder.check(try Self.record(pid: row.pid, argv: argv, labels: label(Self.launchID)))
        #expect(first == .bound(sessionID: Self.launchID, transcriptRoot: nil, directory: nil))

        let afterNew = try await rig.binder.check(try Self.record(pid: row.pid, argv: argv, labels: label(Self.otherID)))
        #expect(afterNew == .bound(sessionID: Self.otherID, transcriptRoot: nil, directory: nil))
        #expect(await rig.cleared.isEmpty)
    }

    /// Its label outranks the id a launch gave, which `/new` leaves behind in the argv.
    @Test func thePluginsLabelOutranksTheLaunchID() async throws {
        let (rig, row) = try await Self.openCodeRig()
        let hint = #"{"session":"\#(Self.otherID)","pid":\#(row.pid),"start":"\#(row.start)"}"#

        let evidence = try await rig.binder.check(
            try Self.record(
                pid: row.pid, argv: ["opencode", "-s", Self.launchID],
                labels: [Self.openCodeLabel: Self.launchID, "heeler.session": hint]))

        #expect(evidence == .bound(sessionID: Self.otherID, transcriptRoot: nil, directory: nil))
    }

    @Test func aLabelThatNamesNoOpenCodeSessionBindsNothing() async throws {
        let (rig, row) = try await Self.openCodeRig()
        let hint = #"{"session":"not-a-session","pid":\#(row.pid),"start":"\#(row.start)"}"#

        let evidence = try await rig.binder.check(try Self.record(for: row, labels: ["heeler.session": hint]))

        #expect(evidence == .unavailable(.cannotTellSession(.opencode)))
    }

    /// The service OpenCode starts carries the Terminal's scope and holds the
    /// database. Nothing of it is the Agent.
    @Test func theServiceIsNotTheAgent() async throws {
        let (rig, row) = try await Self.openCodeRig()
        let service = try #require(
            try HostEvidenceFixture.named("opencode/ses-flag-2.2.5").scene("first-terminal").processes?.last)
        let hint = #"{"session":"\#(Self.otherID)","pid":\#(service.pid),"start":"\#(service.start)"}"#

        let evidence = try await rig.binder.check(try Self.record(for: row, labels: ["heeler.session": hint]))

        #expect(evidence == .unavailable(.cannotTellSession(.opencode)))
    }

    @Test func theCheckAsksOnlyForTheScope() async throws {
        let (rig, row) = try await Self.openCodeRig()

        _ = try await rig.binder.check(try Self.record(for: row))

        let request = try #require(await rig.table.requests.first)
        #expect(request.valuesOf == ["HC_SCOPE"])
        #expect(request.namesOf.isEmpty && !request.readsOpenFiles && request.argumentsAmong.isEmpty)
    }

    // MARK: Antigravity CLI

    private static let agyHome = "/Users/developer"
    private static let agyRoot = "\(agyHome)/.gemini/antigravity-cli"

    private static func agyLock(_ session: String, root: String = agyRoot) -> String {
        "\(root)/presence/\(session).lock"
    }

    /// One scene of agy's macOS recording, with its rows as recorded, or the Agent's
    /// open files replaced.
    private static func agyRig(
        _ name: String, holding files: (([String]) -> [String])? = nil
    ) async throws -> (Rig, HerdrCoreTerminalRecord) {
        let scene = try HostEvidenceFixture.named("agy/presence-lock-1.5.3").scene(name)
        var row = try firstRow(scene)
        if let files { row.files = files(row.files) }
        let rig = Rig(program: .agy)
        await rig.add([row])
        return (rig, try record(for: row))
    }

    private static func agyEvidence(
        _ name: String, holding files: (([String]) -> [String])? = nil
    ) async throws -> ChatSessionEvidence {
        let (rig, record) = try await agyRig(name, holding: files)
        return try await rig.binder.check(record)
    }

    private static func agyBound(_ session: String, root: String = agyRoot) -> ChatSessionEvidence {
        .bound(sessionID: session, transcriptRoot: root, directory: nil)
    }

    /// The reader's own macOS read of a probe's agy after its first reply: one lock
    /// among 79 open files, and the check reads none of them.
    @Test func anAntigravityCLIBindsTheOneLockItHolds() async throws {
        let (rig, record) = try await Self.agyRig("after-first-prompt")

        let evidence = try await rig.binder.check(record)

        #expect(evidence == Self.agyBound("00000000-0000-4000-8000-000000000103"))
        #expect(await rig.table.requests.count == 1)
        #expect(await rig.reads.isEmpty)
        #expect(await rig.files.statuses.isEmpty)
        #expect(await rig.files.listings.isEmpty)
    }

    /// A new conversation exists only from its first prompt, so the same process two
    /// minutes earlier, a bare `agy` in the core's record, has none yet. The recording
    /// kept no argv, and a foreground whose argv the core does not give says nothing
    /// of how agy started, so that one cannot tell.
    @Test func atItsPromptABareAntigravityCLIHasNoConversationYet() async throws {
        let (rig, unnamed) = try await Self.agyRig("at-prompt")
        let row = try Self.firstRow(try HostEvidenceFixture.named("agy/presence-lock-1.5.3").scene("at-prompt"))
        let bare = try Self.record(pid: row.pid, argv: ["agy"], name: row.name)

        #expect(unnamed.foreground?.argv == [])
        #expect(try await rig.binder.check(bare) == .unavailable(.noConversationYet(.agy)))
        #expect(try await rig.binder.check(unnamed) == .unavailable(.cannotTellSession(.agy)))
    }

    /// `/clear` and `/fork` move the lock at once, and the conversation left behind
    /// keeps its folder and database open.
    @Test(arguments: [
        ("follow-after-reply", "00000000-0000-4000-8000-000000000102"),
        ("follow-after-clear", "00000000-0000-4000-8000-000000000101"),
        ("follow-after-fork", "00000000-0000-4000-8000-000000000105"),
        ("resumed-by-id", "00000000-0000-4000-8000-000000000101"),
        ("resumed-then-clear", "00000000-0000-4000-8000-000000000104"),
        ("first-instance", "00000000-0000-4000-8000-000000000102"),
    ])
    func theConversationOnScreenIsTheOneWhoseLockIsHeld(_ scene: String, _ session: String) async throws {
        #expect(try await Self.agyEvidence(scene) == Self.agyBound(session))
    }

    /// A second agy on a conversation already open holds its folder and database and
    /// never the lock, and neither says which agy shows it. Its `--conversation`
    /// names the same one, which lists once, ranks as held open, and is dated by its
    /// transcript.
    @Test func aSecondAntigravityCLIOnAnOpenConversationCannotTell() async throws {
        let (rig, record) = try await Self.agyRig("second-instance")
        let session = "00000000-0000-4000-8000-000000000102"
        let transcript = AgyTranscriptLocator.transcriptPath(
            inFolder: AgyTranscriptLocator.folder(in: Self.agyRoot, id: session))
        await rig.files.write(Data("{}\n".utf8), at: transcript)
        let written = try #require(try await rig.files.fileStatus(atPath: transcript)?.modificationTime)

        #expect(record.foreground?.argv == ["agy", "--conversation", session])
        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.agy)))
        let answer = try await rig.binder.candidates(of: record)
        guard case .listed(let list) = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
        #expect(list.transcriptRoot == Self.agyRoot)
        #expect(list.candidates.map(\.sessionID) == [session])
        #expect(list.candidates.map(\.origins) == [[.heldOpen, .commandLine]])
        #expect(list.candidates.map(\.modified) == [Date(timeIntervalSince1970: TimeInterval(written))])
        // agy files conversations by id, so there is no directory to list.
        #expect(await rig.files.listings.isEmpty)
        #expect(await rig.reads.isEmpty)
    }

    /// Edited: the second agy also holds another conversation's folder, whose id
    /// sorts after the named one's. Held open and named, the named one ranks with
    /// what is held open, not below it.
    @Test func aConversationHeldOpenAndNamedRanksAsHeldOpen() async throws {
        let held = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
        let (rig, record) = try await Self.agyRig("second-instance") { $0 + ["\(Self.agyRoot)/brain/\(held)"] }

        let answer = try await rig.binder.candidates(of: record)
        guard case .listed(let list) = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
        #expect(list.candidates.map(\.sessionID) == ["00000000-0000-4000-8000-000000000102", held])
        #expect(list.candidates.map(\.origins) == [[.heldOpen, .commandLine], [.heldOpen]])
    }

    /// The recording after `/clear`, with the new lock let go: the folder and database
    /// of the conversation left behind bind nothing.
    @Test func aClearedConversationsFolderAndDatabaseAloneBindNothing() async throws {
        let evidence = try await Self.agyEvidence("follow-after-clear") { $0.filter { !$0.contains("/presence/") } }

        #expect(evidence == .unavailable(.cannotTellSession(.agy)))
    }

    /// Edited: a second held lock, which one process never showed. Nothing says which
    /// is on screen. lsof's second row for the same lock is still one.
    @Test func twoHeldLocksBindNothing() async throws {
        let other = Self.agyLock("0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11")

        #expect(
            try await Self.agyEvidence("after-first-prompt") { $0 + [other] }
                == .unavailable(.cannotTellSession(.agy)))
        #expect(
            try await Self.agyEvidence("after-first-prompt") { $0 + [Self.agyLock("00000000-0000-4000-8000-000000000103")] }
                == Self.agyBound("00000000-0000-4000-8000-000000000103"))
    }

    /// Lock files stay after their process exits. One on disk that the Agent does not
    /// hold counts for nothing, and the check never looks at the folder.
    @Test func aStaleLockFileThatIsNotHeldCountsForNothing() async throws {
        let (rig, record) = try await Self.agyRig("at-prompt")
        for session in ["00000000-0000-4000-8000-000000000102", "00000000-0000-4000-8000-000000000103"] {
            await rig.files.write("", at: Self.agyLock(session))
        }

        #expect(try await rig.binder.check(record) == .unavailable(.cannotTellSession(.agy)))
        #expect(await rig.files.statuses.isEmpty)
        #expect(await rig.files.listings.isEmpty)
    }

    /// Written for the test: held files that are no conversation's lock. Alone they
    /// bind nothing, and beside the real lock they are no second one.
    @Test(arguments: [
        "\(agyRoot)/presence/not-a-conversation.lock",
        "\(agyRoot)/presence/00000000000040008000000000000103.lock",
        "\(agyRoot)/presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.lock.tmp",
        "\(agyRoot)/presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11",
        "\(agyRoot)/presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11/held.lock",
        "\(agyRoot)/locks/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.lock",
        "\(agyHome)/.gemini/config/projects/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.json",
        "\(agyRoot)/brain/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11",
        "\(agyRoot)/conversations/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.db",
    ])
    func aHeldFileThatIsNoLockIsIgnored(_ path: String) async throws {
        let withoutLock: ([String]) -> [String] = { $0.filter { !$0.contains("/presence/") } + [path] }
        #expect(try await Self.agyEvidence("after-first-prompt", holding: withoutLock) == .unavailable(.cannotTellSession(.agy)))
        #expect(
            try await Self.agyEvidence("after-first-prompt") { $0 + [path] }
                == Self.agyBound("00000000-0000-4000-8000-000000000103"))
    }

    /// Written for the test: a lock whose root a read cannot take names no root to
    /// read, so it counts for nothing, beside the real lock too.
    @Test(arguments: [
        "/presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.lock",
        "presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.lock",
        "relative/root/presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.lock",
        "\(agyHome)/../other/.gemini/antigravity-cli/presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.lock",
        "\(agyHome)/line\nbreak/presence/0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.lock",
    ])
    func aLockUnderARootNoReadCanTakeIsIgnored(_ path: String) async throws {
        #expect(HerdrCoreSessionBinder.antigravityLock(held: path) == nil)
        #expect(
            try await Self.agyEvidence("after-first-prompt") { $0 + [path] }
                == Self.agyBound("00000000-0000-4000-8000-000000000103"))
    }

    /// The bound root is the one the lock names, which is what the process writes
    /// under. A pick and the list look under the Agent's own `HOME`.
    @Test func theBoundRootIsTheLocksAndTheListsIsTheAgentsHome() async throws {
        let scene = try HostEvidenceFixture.named("agy/presence-lock-1.5.3").scene("after-first-prompt")
        var row = try Self.firstRow(scene)
        row.environment["HOME"] = "/home/link"
        let rig = Rig(program: .agy)
        await rig.add([row])
        let record = try Self.record(for: row)

        #expect(try await rig.binder.check(record) == Self.agyBound("00000000-0000-4000-8000-000000000103"))
        let answer = try await rig.binder.candidates(of: record)
        guard case .listed(let list) = answer else {
            Issue.record("Expected a list, got \(answer)")
            return
        }
        #expect(list.transcriptRoot == "/home/link/.gemini/antigravity-cli")
        #expect(list.candidates.map(\.sessionID) == ["00000000-0000-4000-8000-000000000103"])
    }

    /// Without `HOME` there is no root for a list or a pick, though a held lock still
    /// names its own.
    @Test func anAntigravityCLIWithNoHomeStillBindsAndListsNothing() async throws {
        let scene = try HostEvidenceFixture.named("agy/presence-lock-1.5.3").scene("after-first-prompt")
        var row = try Self.firstRow(scene)
        row.environment["HOME"] = nil
        let rig = Rig(program: .agy)
        await rig.add([row])
        let record = try Self.record(for: row)

        #expect(try await rig.binder.check(record) == Self.agyBound("00000000-0000-4000-8000-000000000103"))
        #expect(try await rig.binder.candidates(of: record) == .noProcess)
    }

    @Test func theAntigravityCheckAsksOnlyWhatItNames() async throws {
        let (rig, record) = try await Self.agyRig("at-prompt")

        _ = try await rig.binder.check(record)

        let request = try #require(await rig.table.requests.first)
        #expect(Set(request.valuesOf) == ["HC_SCOPE", "HOME"])
        #expect(request.namesOf.isEmpty && request.namesWithPrefix.isEmpty)
        #expect(request.readsOpenFiles)
        #expect(request.argumentsAmong.isEmpty)
    }

    // MARK: The rest

    @Test(arguments: [ChatProgram.codex, .grok, .opencode, .agy])
    func aFailedExecBindsNothingAndReadsNothing(_ program: ChatProgram) async throws {
        let rig = Rig(program: program)

        let evidence = try await rig.binder.check(try Self.record(pid: 40, argv: [program.rawValue]))

        #expect(evidence == .unavailable(.cannotTellSession(program)))
        #expect(await rig.reads.isEmpty)
    }

    @Test(arguments: [ChatProgram.codex, .grok, .opencode, .agy])
    func aDescendantOfAnotherScopeIsNotFollowed(_ program: ChatProgram) async throws {
        let rig = Rig(program: program)
        await rig.table.add(
            ScriptedProcessTable.Process(
                pid: 40, name: "sh", start: "1", environment: ["HC_SCOPE": "mine", "HOME": "/home/user"]))
        await rig.table.add(
            ScriptedProcessTable.Process(
                pid: 41, parent: 40, name: program.rawValue, start: "2",
                environment: ["HC_SCOPE": "theirs", "HOME": "/home/user"],
                argv: [program.rawValue]))

        let evidence = try await rig.binder.check(try Self.record(pid: 40, argv: ["sh"]))

        #expect(evidence == .unavailable(.cannotTellSession(program)))
    }
}
