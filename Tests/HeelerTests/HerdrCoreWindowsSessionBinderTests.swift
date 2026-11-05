import Foundation
import Testing

@testable import Heeler

/// The binder on native Windows, through the real Windows read's command and parser
/// over the tree #586 recorded: `powershell.exe` as the foreground, the Agent its
/// child. The start values are FILETIMEs. A Claude Code registry entry carries one in
/// `procStart`, as 2.1.286 and 2.1.316 wrote it on the owner's machine, or in
/// `procStartFt`, the field its source names. Grok Build 1.0.70's rows there had
/// no `pid_start`, only `opened_at`; a `pid_start` holding the FILETIME is assumed
/// (`docs/agents/herdr-compatibility.md`).
@Suite("herdr-core session binder on native Windows")
struct HerdrCoreWindowsSessionBinderTests {
    private static let session = "11111111-1111-4111-8111-111111111111"
    private static let other = "22222222-2222-4222-8222-222222222222"
    private static let home = "/C:/Users/me"
    private static let shellPid = 7868
    private static let agentPid = 3792
    private static let agentStart = "134065000000000002"
    private static let scope = "scope-token-7"

    private actor Execs {
        var scripts: [String] = []
        func add(_ script: String) { scripts.append(script) }
    }

    private actor LabelLog {
        var cleared: [[String]] = []
        func clear(_ names: [String]) { cleared.append(names) }
    }

    private struct Rig {
        var table = WindowsProcessTable()
        let files = VirtualHostFiles(home: home)
        let execs = Execs()
        let labels = LabelLog()

        init(
            agentImage: String? = "claude.exe", agentEnvironment: [String: String] = [:],
            agentStart: String = HerdrCoreWindowsSessionBinderTests.agentStart
        ) {
            let base = ["HC_SCOPE": scope, "USERPROFILE": "C:\\Users\\me", "SECRET": "never"]
            table.add(
                .init(
                    pid: shellPid, parent: 100, image: "powershell.exe", start: "134065000000000001",
                    environment: base))
            if let agentImage {
                table.add(
                    .init(
                        pid: agentPid, parent: shellPid, image: agentImage, start: agentStart,
                        environment: base.merging(agentEnvironment) { _, new in new }))
            }
        }

        func binder(_ program: ChatProgram) -> HerdrCoreSessionBinder {
            let table = table
            let execs = execs
            let labels = labels
            return HerdrCoreSessionBinder(
                program: program,
                processes: { request in
                    let nonce = "0123456789abcdef01234567"
                    let command = try HostProcessReader.windowsCommand(request, nonce: nonce)
                    #expect(command.utf8.count <= HostProcessReader.windowsCommandLimit)
                    let script = try HerdrCoreWindowsLocatorTests.decoded(command)
                    await execs.add(script)
                    return try HostProcessReader.parseWindows(
                        stdout: Data(table.output(forScript: script).utf8), nonce: nonce, request: request)
                },
                files: files.hostFiles(),
                clearLabels: { await labels.clear($0.keys.sorted()) },
                hostSystem: .windows)
        }

        var execCount: Int {
            get async { await execs.scripts.count }
        }

        var readPaths: [String] {
            get async { await files.reads.map(\.path) }
        }
    }

    private static func record(labels: [String: String] = [:]) throws -> HerdrCoreTerminalRecord {
        let value = JSONValue.object([
            "address": .string("t7"), "cwd": .string("C:\\proj"), "state": .string("live"),
            "argv": .array([.string("powershell.exe")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null,
            "pid": .number(Double(shellPid)), "reason": .null,
            "labels": .object(labels.mapValues(JSONValue.string)),
            "foreground": .object([
                "pid": .number(Double(shellPid)), "name": .string("powershell.exe"),
                "argv": .array([.string("powershell.exe")]), "cwd": .string("C:\\proj"),
            ]),
        ])
        return try JSONDecoder().decode(HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(value))
    }

    private static func entry(
        pid: Int = agentPid, session: String = session, start: String = agentStart, field: String = "procStartFt"
    ) -> Data {
        Data(
            """
            {"pid":\(pid),"sessionId":"\(session)","cwd":"C:\\\\proj","\(field)":"\(start)","kind":"interactive"}
            """.utf8)
    }

    private static let registryPath = "\(home)/.claude/sessions/\(agentPid).json"

    // MARK: Claude Code

    @Test("Claude Code binds when its entry's start is the agent process's creation time")
    func claudeBinds() async throws {
        let rig = Rig()
        await rig.files.write(Self.entry(), at: Self.registryPath)
        await rig.files.write(Data("secret".utf8), at: "\(Self.home)/.claude/sessions/\(Self.agentPid).abc.key")

        let evidence = try await rig.binder(.claude).check(try Self.record())

        #expect(
            evidence == .bound(sessionID: Self.session, transcriptRoot: "\(Self.home)/.claude", directory: "C:\\proj"))
        #expect(await rig.execCount == 1)
        #expect(await rig.readPaths == [Self.registryPath])
        #expect(await rig.files.listings.isEmpty)
    }

    @Test("Claude Code binds nothing when the start differs, and reads no key file")
    func claudeMismatch() async throws {
        let rig = Rig()
        await rig.files.write(Self.entry(start: "134065000000000099"), at: Self.registryPath)
        await rig.files.write(Data("secret".utf8), at: "\(Self.home)/.claude/sessions/\(Self.agentPid).abc.key")

        let evidence = try await rig.binder(.claude).check(try Self.record())

        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(.claude)))
        #expect(await rig.execCount == 1)
        #expect(await rig.readPaths == [Self.registryPath])
        #expect(await rig.files.listings.isEmpty)
    }

    @Test("Claude Code binds from procStart, where 2.1.286 and 2.1.316 wrote the creation time on Windows")
    func claudeBindsFromProcStart() async throws {
        let rig = Rig()
        await rig.files.write(Self.entry(field: "procStart"), at: Self.registryPath)

        let evidence = try await rig.binder(.claude).check(try Self.record())

        #expect(
            evidence == .bound(sessionID: Self.session, transcriptRoot: "\(Self.home)/.claude", directory: "C:\\proj"))
        #expect(await rig.readPaths == [Self.registryPath])
    }

    @Test("An entry written for another pid binds nothing")
    func claudeOtherPid() async throws {
        let rig = Rig()
        await rig.files.write(Self.entry(pid: 9), at: Self.registryPath)
        #expect(
            try await rig.binder(.claude).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.claude)))
    }

    @Test("The foreground PowerShell is never the Agent, whatever an entry under its pid says")
    func powerShellIsNeverTheAgent() async throws {
        let rig = Rig(agentImage: nil)
        await rig.files.write(
            Self.entry(pid: Self.shellPid, start: "134065000000000001"),
            at: "\(Self.home)/.claude/sessions/\(Self.shellPid).json")

        let evidence = try await rig.binder(.claude).check(try Self.record())

        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(.claude)))
        #expect(await rig.readPaths.isEmpty)
    }

    @Test("An npm install runs under node.exe, and its entry names that process")
    func claudeUnderNode() async throws {
        let rig = Rig(agentImage: "node.exe")
        await rig.files.write(Self.entry(), at: Self.registryPath)

        let evidence = try await rig.binder(.claude).check(try Self.record())

        #expect(
            evidence == .bound(sessionID: Self.session, transcriptRoot: "\(Self.home)/.claude", directory: "C:\\proj"))
    }

    @Test("Two runtimes equally near bind nothing, and read nothing")
    func twoRuntimes() async throws {
        var rig = Rig(agentImage: "node.exe")
        rig.table.add(
            .init(
                pid: 4000, parent: Self.shellPid, image: "node.exe", start: Self.agentStart,
                environment: ["HC_SCOPE": Self.scope]))
        let evidence = try await rig.binder(.claude).check(try Self.record())
        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(.claude)))
        #expect(await rig.readPaths.isEmpty)
    }

    @Test("A process of another scope is not the Agent")
    func anotherScope() async throws {
        let rig = Rig(agentEnvironment: ["HC_SCOPE": "another"])
        await rig.files.write(Self.entry(), at: Self.registryPath)
        let evidence = try await rig.binder(.claude).check(try Self.record())
        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(.claude)))
        #expect(await rig.readPaths.isEmpty)
    }

    @Test("The config folder comes from the Agent's own variable in its Windows form")
    func claudeConfigDirectory() async throws {
        let rig = Rig(agentEnvironment: ["CLAUDE_CONFIG_DIR": "D:\\cfg\\claude"])
        await rig.files.write(Self.entry(), at: "/D:/cfg/claude/sessions/\(Self.agentPid).json")

        let evidence = try await rig.binder(.claude).check(try Self.record())

        #expect(evidence == .bound(sessionID: Self.session, transcriptRoot: "/D:/cfg/claude", directory: "C:\\proj"))
    }

    @Test("The read names only the program's own variables")
    func namesOnlyWhatItUses() async throws {
        let rig = Rig()
        _ = try await rig.binder(.claude).check(try Self.record())
        let script = try #require(await rig.execs.scripts.first)
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.contains("$want=@('HC_SCOPE','USERPROFILE','CLAUDE_CONFIG_DIR')"))
        #expect(lines.contains("$names=@('CLAUDE_CODE_CHILD_SESSION','CLAUDE_CODE_SKIP_PROMPT_HISTORY')"))
        #expect(!script.contains("SECRET"))
        #expect(!script.contains("HERDR_"))
    }

    @Test("A label with no start is never adopted")
    func labelWithoutStart() async throws {
        let rig = Rig()
        let label = "{\"session\":\"\(Self.session)\",\"pid\":\(Self.agentPid)}"
        let evidence = try await rig.binder(.claude).check(try Self.record(labels: ["heeler.chat": label]))
        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(.claude)))
        #expect(await rig.labels.cleared == [["heeler.chat"]])
    }

    // MARK: Grok Build

    private static let grokPath = "\(home)/.grok/active_sessions.json"

    private static func row(session: String = session, pid: Int = agentPid, start: String = agentStart) -> String {
        "{\"session_id\":\"\(session)\",\"pid\":\(pid),\"pid_start\":\(start),\"cwd\":\"C:\\\\proj\"}"
    }

    @Test("Grok Build binds from the one row whose pid and start match")
    func grokBinds() async throws {
        let rig = Rig(agentImage: "grok.exe")
        let rows =
            "[\(Self.row(session: Self.other, pid: 11)),\(Self.row(session: Self.other, start: "134065000000000099")),\(Self.row())]"
        await rig.files.write(Data(rows.utf8), at: Self.grokPath)

        let evidence = try await rig.binder(.grok).check(try Self.record())

        #expect(evidence == .bound(sessionID: Self.session, transcriptRoot: "\(Self.home)/.grok", directory: "C:\\proj"))
        #expect(await rig.execCount == 1)
        #expect(await rig.readPaths == [Self.grokPath])
    }

    @Test("Grok Build binds from no other row")
    func grokOtherRows() async throws {
        let rig = Rig(agentImage: "grok.exe")
        let rows = "[\(Self.row(session: Self.other, pid: 11)),\(Self.row(session: Self.other, start: "134065000000000099"))]"
        await rig.files.write(Data(rows.utf8), at: Self.grokPath)

        #expect(try await rig.binder(.grok).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.grok)))
    }

    @Test("Two matching rows bind nothing")
    func grokTwoRows() async throws {
        let rig = Rig(agentImage: "grok.exe")
        await rig.files.write(Data("[\(Self.row()),\(Self.row(session: Self.other))]".utf8), at: Self.grokPath)

        #expect(try await rig.binder(.grok).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.grok)))
    }

    /// Grok Build 1.0.70's rows on the owner's machine, which have no `pid_start`, and
    /// `grok.exe`'s creation FILETIME there, 2 s before the row was opened
    /// (`docs/agents/herdr-compatibility.md`).
    private static let grokCreated = "134381662108367563"

    private static func openedRow(session: String = session, pid: Int = agentPid, openedAt: String) -> String {
        "{\"session_id\":\"\(session)\",\"pid\":\(pid),\"cwd\":\"C:\\\\proj\",\"opened_at\":\"\(openedAt)\"}"
    }

    @Test("Grok Build 1.0.70 binds from the row its process opened, which has no pid_start")
    func grokBindsFromOpenedAt() async throws {
        let rig = Rig(agentImage: "grok.exe", agentStart: Self.grokCreated)
        let rows =
            "[\(Self.openedRow(session: Self.other, pid: 11, openedAt: "2026-11-03T07:56:52.816690400Z")),"
            + "\(Self.openedRow(openedAt: "2026-11-03T07:56:52.816690400Z"))]"
        await rig.files.write(Data(rows.utf8), at: Self.grokPath)

        let evidence = try await rig.binder(.grok).check(try Self.record())

        #expect(evidence == .bound(sessionID: Self.session, transcriptRoot: "\(Self.home)/.grok", directory: "C:\\proj"))
        #expect(await rig.readPaths == [Self.grokPath])
    }

    @Test("A row opened before the process was created is an earlier process's with the same pid")
    func grokRefusesARowFromBeforeTheProcess() async throws {
        let rig = Rig(agentImage: "grok.exe", agentStart: Self.grokCreated)
        // 07:56:50.8367562Z is one tick before the creation time.
        for openedAt in ["2026-11-03T07:56:50.8367562Z", "2026-11-03T07:40:00Z"] {
            await rig.files.write(Data("[\(Self.openedRow(openedAt: openedAt))]".utf8), at: Self.grokPath)
            #expect(
                try await rig.binder(.grok).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.grok)),
                "\(openedAt)")
        }
        await rig.files.write(
            Data("[\(Self.openedRow(openedAt: "2026-11-03T07:56:50.8367563Z"))]".utf8), at: Self.grokPath)
        #expect(
            try await rig.binder(.grok).check(try Self.record())
                == .bound(sessionID: Self.session, transcriptRoot: "\(Self.home)/.grok", directory: "C:\\proj"))
    }

    /// `/new` on the owner's machine added a second row for the same pid and kept the first.
    @Test("After /new two rows of the process bind nothing")
    func grokTwoOpenedRows() async throws {
        let rig = Rig(agentImage: "grok.exe", agentStart: Self.grokCreated)
        let rows =
            "[\(Self.openedRow(openedAt: "2026-11-03T07:56:52.816690400Z")),"
            + "\(Self.openedRow(session: Self.other, openedAt: "2026-11-03T07:59:10.638095400Z"))]"
        await rig.files.write(Data(rows.utf8), at: Self.grokPath)

        #expect(try await rig.binder(.grok).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.grok)))
    }

    @Test("A row with neither pid_start nor opened_at, or an opened_at in another form, binds nothing")
    func grokRowsWithoutAStart() async throws {
        let rig = Rig(agentImage: "grok.exe", agentStart: Self.grokCreated)
        let bare = "{\"session_id\":\"\(Self.other)\",\"pid\":11,\"cwd\":\"C:\\\\proj\"}"
        await rig.files.write(
            Data("[\(bare),\(Self.openedRow(openedAt: "2026-11-03T07:56:52.816690400Z"))]".utf8), at: Self.grokPath)
        #expect(try await rig.binder(.grok).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.grok)))

        await rig.files.write(
            Data("[\(Self.openedRow(openedAt: "2026-11-03 07:56:52"))]".utf8), at: Self.grokPath)
        #expect(try await rig.binder(.grok).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.grok)))
    }

    @Test("opened_at reads as a FILETIME to its seventh decimal")
    func openedAtAsAFileTime() {
        #expect(HerdrCoreSessionBinder.windowsFileTime(ofUTC: "2026-11-03T07:56:50.8367563Z") == 134_381_662_108_367_563)
        #expect(HerdrCoreSessionBinder.windowsFileTime(ofUTC: "2026-11-03T07:56:52.816690400Z") == 134_381_662_128_166_904)
        #expect(HerdrCoreSessionBinder.windowsFileTime(ofUTC: "1970-01-01T00:00:00Z") == 116_444_736_000_000_000)
        #expect(HerdrCoreSessionBinder.windowsFileTime(ofUTC: "2026-02-30T00:00:00Z") == nil)
        #expect(HerdrCoreSessionBinder.windowsFileTime(ofUTC: "2026-11-03T07:56:52+08:00") == nil)
    }

    @Test("Grok Build does not bind through a runtime or PowerShell")
    func grokStrictName() async throws {
        let rig = Rig(agentImage: "node.exe")
        await rig.files.write(Data("[\(Self.row())]".utf8), at: Self.grokPath)

        #expect(try await rig.binder(.grok).check(try Self.record()) == .unavailable(.cannotTellSessionOnWindows(.grok)))
        #expect(await rig.readPaths.isEmpty)
    }

    // MARK: Pi and Oh My Pi

    private static func label(
        session: String = session, pid: Int = agentPid, start: String? = agentStart, file: String? = nil
    ) throws -> String {
        var fields: [String: JSONValue] = ["session": .string(session), "pid": .number(Double(pid))]
        if let start { fields["start"] = .string(start) }
        if let file { fields["file"] = .string(file) }
        return String(decoding: try JSONEncoder().encode(JSONValue.object(fields)), as: UTF8.self)
    }

    private static let piFile = "C:\\Users\\me\\.pi\\agent\\sessions\\--C--proj--\\2026-11-01T00-00-00_\(session).jsonl"

    @Test("Pi's label is adopted on a pid and creation-time match, its file as SFTP opens it", arguments: ["pi.exe", "node.exe"])
    func piAdopts(image: String) async throws {
        let rig = Rig(agentImage: image)
        let evidence = try await rig.binder(.pi).check(
            try Self.record(labels: ["heeler.session": try Self.label(file: Self.piFile)]))
        #expect(
            evidence == .bound(
                sessionID: "/C:/Users/me/.pi/agent/sessions/--C--proj--/2026-11-01T00-00-00_\(Self.session).jsonl",
                transcriptRoot: "\(Self.home)/.pi/agent/sessions", directory: nil))
        #expect(await rig.execCount == 1)
        #expect(await rig.readPaths.isEmpty)
    }

    @Test("Oh My Pi's label is adopted on a match, under its own profile")
    func ompAdopts() async throws {
        let rig = Rig(agentImage: "omp.exe", agentEnvironment: ["OMP_PROFILE": "work"])
        let evidence = try await rig.binder(.omp).check(
            try Self.record(labels: ["heeler.session": try Self.label()]))
        #expect(
            evidence == .bound(
                sessionID: Self.session, transcriptRoot: "\(Self.home)/.omp/profiles/work/agent/sessions",
                directory: nil))
    }

    @Test(
        "A label is cleared and not adopted unless both pid and creation time match",
        arguments: [
            (pid: 3792, start: "134065000000000099"), (pid: 11, start: "134065000000000002"),
            (pid: 7868, start: "134065000000000001"),
        ])
    func labelsNeedBoth(pid: Int, start: String) async throws {
        let rig = Rig(agentImage: "pi.exe")
        let evidence = try await rig.binder(.pi).check(
            try Self.record(labels: ["heeler.session": try Self.label(pid: pid, start: start)]))
        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(.pi)))
        #expect(await rig.labels.cleared == [["heeler.session"]])
    }

    @Test("No label binds nothing: no directory, newest file or launch label counts")
    func piWithoutLabel() async throws {
        let rig = Rig(agentImage: "pi.exe")
        await rig.files.write(Data("{}".utf8), at: "\(Self.home)/.pi/agent/sessions/--C--proj--/new_\(Self.session).jsonl")
        let evidence = try await rig.binder(.pi).check(
            try Self.record(labels: [HerdrCoreLaunch.sessionHintLabel: Self.session]))
        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(.pi)))
        #expect(await rig.readPaths.isEmpty)
        #expect(await rig.files.listings.isEmpty)
    }

    /// A read that failed is not a missing extension, and adding one would not help.
    @Test("A process read that fails says so, and offers no extension", arguments: [ChatProgram.pi, .omp, .claude])
    func readThatFails(program: ChatProgram) async throws {
        var rig = Rig(agentImage: "\(program.rawValue).exe")
        rig.table = WindowsProcessTable()
        let evidence = try await rig.binder(program).check(try Self.record())
        #expect(evidence == .unavailable(.cannotReadProcessesOnWindows(program)))
        #expect(!ChatUnavailableReason.cannotReadProcessesOnWindows(program).offersWindowsExtension)
        #expect(ChatUnavailableReason.cannotReadProcessesOnWindows(program).offersRetry)
    }

    /// `E <pid> -`: the Terminal's own environment could not be read, as from an SSH
    /// session that is not elevated against a core that is.
    @Test("A Terminal whose environment cannot be read says the read failed")
    func terminalEnvironmentWithheld() async throws {
        var rig = Rig(agentImage: "pi.exe")
        rig.table.processes[Self.shellPid]?.environment = nil
        let evidence = try await rig.binder(.pi).check(try Self.record())
        #expect(evidence == .unavailable(.cannotReadProcessesOnWindows(.pi)))
    }

    // MARK: Programs with no Chat here

    @Test("Codex and OpenCode cost no exec and no read", arguments: [ChatProgram.codex, .opencode])
    func programsOutOfScope(program: ChatProgram) async throws {
        let rig = Rig(agentImage: "\(program.rawValue).exe")
        let evidence = try await rig.binder(program).check(try Self.record())
        #expect(evidence == .unavailable(.cannotTellSessionOnWindows(program)))
        #expect(await rig.execCount == 0)
        #expect(await rig.readPaths.isEmpty)
    }

    // MARK: Transcripts

    @Test("Claude Code's Transcript is looked for under the Windows directory's key")
    func claudeKey() {
        #expect(ClaudeTranscriptLocator.plan(directories: ["C:\\proj"]).exactKeys.contains("C--proj"))
    }

    // MARK: What Chat says

    @Test("Chat's reason here never offers the Helper", arguments: ChatProgram.allCases)
    func reasonNeverOffersHelper(program: ChatProgram) {
        let reason = ChatUnavailableReason.cannotTellSessionOnWindows(program)
        #expect(!reason.explanation.localizedCaseInsensitiveContains("helper"))
        #expect(!reason.explanation.localizedCaseInsensitiveContains("install"))
        #expect(!reason.offersOpenCodePluginEdit)
        #expect(reason.offersRetry)
    }
}
