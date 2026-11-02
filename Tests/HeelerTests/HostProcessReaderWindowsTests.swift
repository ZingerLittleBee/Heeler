import Foundation
import Testing

@testable import Heeler

/// What the Windows process read may carry, and how the lines it prints parse.
/// Nothing here runs PowerShell, and it has not run on a Windows machine
/// (`docs/agents/herdr-compatibility.md`).
@Suite("Host process reader on native Windows")
struct HostProcessReaderWindowsTests {
    private static let nonce = "0123456789abcdef01234567"

    private static let binderRequest = HostProcessReader.Request(
        pids: ["7868"],
        readsStart: true,
        valuesOf: ["HC_SCOPE", "HOME", "CLAUDE_CONFIG_DIR", "GROK_HOME", "PI_CODING_AGENT_DIR", "OMP_PROFILE"],
        namesOf: ["CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SIMPLE"],
        readsOpenFiles: true,
        argumentsAmong: ["--no-daemon"],
        descendantsOf: "7868")

    private func decoded(_ request: HostProcessReader.Request) throws -> String {
        try HerdrCoreWindowsLocatorTests.decoded(HostProcessReader.windowsCommand(request, nonce: Self.nonce))
    }

    @Test("The largest read a binder asks for fits what cmd.exe takes, and a larger one is refused")
    func fitsTheCommandLine() throws {
        let command = try HostProcessReader.windowsCommand(Self.binderRequest, nonce: Self.nonce)
        #expect(command.utf8.count <= HostProcessReader.windowsCommandLimit)
        let pids = (1...HostProcessReader.processCap).map { String(4_000_000_000 + $0) }
        let tooMany = HostProcessReader.Request(
            pids: pids, readsStart: true, valuesOf: Self.binderRequest.valuesOf, descendantsOf: pids[0])
        #expect(throws: HostProcessReader.Refusal.self) {
            _ = try HostProcessReader.windowsCommand(tooMany, nonce: Self.nonce)
        }
    }

    @Test("Only the variables asked for are named, and HOME is the Windows home")
    func namesOnlyWhatItAsks() throws {
        let script = try decoded(
            .init(pids: ["7868"], valuesOf: ["HC_SCOPE", "HOME"], namesOf: ["CLAUDE_CODE_CHILD_SESSION"]))
        let lines = script.split(separator: "\n").map(String.init)
        #expect(lines.contains("$want=@('HC_SCOPE','USERPROFILE')"))
        #expect(lines.contains("$names=@('CLAUDE_CODE_CHILD_SESSION')"))
        #expect(lines.contains("$ids=@(7868)"))
        // Every value leaves through these two lists, never the block itself.
        #expect(!script.contains("say $b"))
        #expect(!script.contains("say $e"))
    }

    @Test("A prefix prints a whole plain name and never a value, and a read with none matches nothing")
    func namesWithAPrefix() throws {
        let check = try decoded(HerdrCoreEnvironmentCheck.request(pid: 7868))
        let lines = check.split(separator: "\n").map(String.init)
        #expect(lines.contains("$pre='^(?:HERDR_)[A-Z0-9_]*$'"))
        #expect(lines.contains("$want=@()"))
        // The one line that names a variable by a prefix prints what `N` prints.
        let naming = try #require(lines.first { $0.contains("-cmatch$pre") })
        #expect(naming.contains(#"say "N $p $($n.ToUpper())""#))
        #expect(!naming.contains("$v)"))
        #expect(!naming.contains("hexOf"))

        let without = try decoded(Self.binderRequest).split(separator: "\n").map(String.init)
        #expect(without.contains("$pre=''"))
    }

    @Test("The core's environment check fits the command line")
    func theEnvironmentCheckFits() throws {
        let command = try HostProcessReader.windowsCommand(
            HerdrCoreEnvironmentCheck.request(pid: 4_294_967_295), nonce: Self.nonce)
        #expect(command.utf8.count <= HostProcessReader.windowsCommandLimit)
    }

    @Test("A read with no walk asks for no tree")
    func noWalkNoList() throws {
        let script = try decoded(.init(pids: ["7868"], readsStart: true))
        #expect(script.split(separator: "\n").map(String.init).contains("$root=0"))
        #expect(!script.contains("gcim"))
    }

    @Test("A process's memory and times are opened for reading only")
    func readsOnly() throws {
        let script = try decoded(Self.binderRequest)
        // QUERY_INFORMATION | VM_READ.
        #expect(script.contains("OpenProcess(0x410,false,p)"))
        for writes in ["WriteProcessMemory", "CreateRemoteThread", "TerminateProcess", "Start-Process", "Invoke-Expression", "iex "] {
            #expect(!script.contains(writes))
        }
    }

    @Test("No function the script defines is shadowed by a PowerShell alias")
    func helpersAreNotAliases() throws {
        // An alias wins over a function, and `rd` deletes.
        let aliases: Set<String> = [
            "%", "?", "ac", "cat", "cd", "clc", "cli", "cls", "copy", "cp", "del", "diff", "dir", "echo", "erase",
            "fl", "foreach", "ft", "fw", "gc", "gi", "gm", "gp", "gps", "group", "gv", "h", "kill", "ls", "md", "mi",
            "mount", "mv", "ni", "nv", "ps", "pwd", "r", "rd", "ren", "ri", "rm", "rmdir", "rp", "rv", "sc", "select",
            "set", "si", "sl", "sleep", "sort", "sp", "start", "sv", "type", "where",
        ]
        let script = try decoded(Self.binderRequest)
        let defined = script.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("function "), let open = line.firstIndex(of: "(") else { return nil }
            return String(line[line.index(line.startIndex, offsetBy: "function ".count)..<open])
        }
        #expect(!defined.isEmpty)
        for name in defined { #expect(!aliases.contains(name.lowercased()), "\(name)") }
    }

    @Test("A bad pid, name or argument stays out of the command")
    func refusals() {
        let bad: [HostProcessReader.Request] = [
            .init(pids: ["1;calc"]),
            .init(pids: ["1"], valuesOf: ["A'B"]),
            .init(pids: ["1"], valuesOf: ["lower"]),
            .init(pids: ["1"], namesOf: ["A B"]),
            .init(pids: ["1"], namesWithPrefix: ["HERDR'"]),
            .init(pids: ["1"], namesWithPrefix: ["herdr_"]),
            .init(pids: ["1"], descendantsOf: "2"),
        ]
        for request in bad {
            #expect(throws: HostProcessReader.Refusal.self) {
                _ = try HostProcessReader.windowsCommand(request, nonce: Self.nonce)
            }
        }
    }

    /// The lines the script's body printed under PowerShell 7 with its native calls
    /// stubbed, for the recorded tree `powershell.exe 7868 -> claude.exe 3792`
    /// (#586). A shell banner comes first and a bad image name reads `-`.
    private static let printed = """
        Windows PowerShell banner

        __HEELER_PROC_BEGIN_0123456789abcdef01234567
        S 7868 134065000000000001
        V 7868 HC_SCOPE 7363
        V 7868 HOME 433a5c55736572735c6d65
        E 7868 ok
        O 7868 -
        B 7868 -
        T 7868 100 powershell.exe
        T 3792 7868 Claude.EXE
        T 5555 3792 -
        W 7868 ok
        S 3792 134065000000000002
        V 3792 HOME 433a5c55736572735c6d65
        V 3792 CLAUDE_CONFIG_DIR 433a2f55736572732f6d652f2e77696e
        N 3792 CLAUDE_CODE_CHILD_SESSION
        E 3792 ok
        O 3792 -
        B 3792 -
        S 5555 -
        E 5555 -
        O 5555 -
        B 5555 -

        __HEELER_PROC_END_0123456789abcdef01234567

        """

    private static let printedRequest = HostProcessReader.Request(
        pids: ["7868"],
        readsStart: true,
        valuesOf: ["HC_SCOPE", "HOME", "CLAUDE_CONFIG_DIR"],
        namesOf: ["CLAUDE_CODE_CHILD_SESSION"],
        readsOpenFiles: true,
        argumentsAmong: ["--no-daemon"],
        descendantsOf: "7868")

    @Test("Images read by the name Linux shows, paths in the form SFTP opens")
    func parsesThePrintedLines() throws {
        let facts = try HostProcessReader.parseWindows(
            stdout: Data(Self.printed.utf8), nonce: Self.nonce, request: Self.printedRequest)
        let shell = try #require(facts["7868"])
        #expect(shell.name == "powershell")
        #expect(shell.start == .value("134065000000000001"))
        #expect(shell.descendants == .value(["3792", "5555"]))
        #expect(shell.variables["HC_SCOPE"] == .value("sc"))
        #expect(shell.variables["HOME"] == .value("/C:/Users/me"))
        #expect(shell.openFiles == .unavailable)
        #expect(shell.arguments == .unavailable)

        let agent = try #require(facts["3792"])
        #expect(agent.name == "claude")
        #expect(agent.parent == "7868")
        #expect(agent.start == .value("134065000000000002"))
        #expect(agent.variables["CLAUDE_CONFIG_DIR"] == .value("/C:/Users/me/.win"))
        #expect(agent.nonEmptyNames == .value(["CLAUDE_CODE_CHILD_SESSION"]))

        let unreadable = try #require(facts["5555"])
        #expect(unreadable.name == "-")
        #expect(unreadable.start == .unavailable)
        #expect(unreadable.variables["HOME"] == .unavailable)
    }

    @Test("A read cut short answers nothing")
    func truncatedThrows() {
        let cut = String(Self.printed.prefix(while: { $0 != "W" }))
        #expect(throws: HostProcessReader.MalformedOutput.self) {
            _ = try HostProcessReader.parseWindows(
                stdout: Data(cut.utf8), nonce: Self.nonce, request: Self.printedRequest)
        }
    }

    @Test("A path SFTP would not open stays refused by the path rules")
    func windowsForSFTP() {
        #expect(RemoteFilePath.windowsForSFTP("C:\\Users\\me") == "/C:/Users/me")
        #expect(RemoteFilePath.windowsForSFTP("c:/Users/me") == "/c:/Users/me")
        #expect(RemoteFilePath.windowsForSFTP("sc") == "sc")
        #expect(RemoteFilePath.windowsForSFTP("/already") == "/already")
        #expect(!RemoteFilePath.isAcceptable(RemoteFilePath.windowsForSFTP("\\\\server\\share\\x")))
        #expect(!RemoteFilePath.isAcceptable(RemoteFilePath.windowsForSFTP("C:\\Users\\..\\x")))
    }

    @Test("The transport reads through one Windows exec, and never the POSIX script")
    func transportUsesOneExec() async throws {
        let host = ScriptedCoreHost(windowsLocator: ScriptedCoreHost.windowsLocatorLines(), channel: .refused)
        await host.setWindowsProcesses([
            .init(
                pid: 7868, parent: 100, image: "powershell.exe", start: "134065000000000001",
                environment: ["USERPROFILE": "C:\\Users\\me", "SECRET": "no"]),
            .init(
                pid: 3792, parent: 7868, image: "claude.exe", start: "134065000000000002",
                environment: ["USERPROFILE": "C:\\Users\\me"]),
        ])
        let transport = await Self.transport(on: host)
        let facts = try await transport.readProcesses(
            .init(pids: ["7868"], readsStart: true, valuesOf: ["HOME"], descendantsOf: "7868"))
        #expect(facts["7868"]?.descendants == .value(["3792"]))
        #expect(facts["3792"]?.name == "claude")
        #expect(facts["3792"]?.start == .value("134065000000000002"))
        #expect(facts["3792"]?.variables["HOME"] == .value("/C:/Users/me"))
        let log = await host.log
        #expect(log.filter { $0 == "windows-process-read" }.count == 1)
        #expect(!log.contains("process-read"))
    }

    @Test("A failed Windows read answers nothing rather than guessing")
    func failedExecAnswersNothing() async throws {
        let host = ScriptedCoreHost(windowsLocator: ScriptedCoreHost.windowsLocatorLines(), channel: .refused)
        await host.setWindowsProcessAnswer(GitExecResult(stdout: Data("half".utf8), stderr: Data(), exitStatus: 1))
        let transport = await Self.transport(on: host)
        let facts = try await transport.readProcesses(.init(pids: ["7868"], readsStart: true))
        #expect(facts.isEmpty)
    }

    private static func transport(on host: ScriptedCoreHost) async -> HerdrCoreSSHTransport {
        await host.helper.configure { $0.platform = .nativeWindows }
        return HerdrCoreSSHTransport(connection: host, session: "x", nonce: { Self.nonce })
    }
}
