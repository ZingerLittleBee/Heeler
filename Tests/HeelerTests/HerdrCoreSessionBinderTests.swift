import Foundation
import Testing

@testable import Heeler

/// A Host's process table as `HostProcessReader` reads it: it answers only what
/// a request names, and counts each request as the one exec it would be.
actor ScriptedProcessTable {
    struct Process: Sendable {
        var pid: Int
        var parent: Int = 1
        var name: String
        var start: String
        var environment: [String: String]
        var argv: [String] = []
        var openFiles: [String] = []
    }

    private var processes: [Int: Process] = [:]
    private var failure: TransportError?
    private(set) var requests: [HostProcessReader.Request] = []
    private var gate: ScriptedTransportCallGate?

    func add(_ process: Process) {
        processes[process.pid] = process
    }

    func remove(_ pid: Int) {
        processes[pid] = nil
    }

    func setFailure(_ failure: TransportError?) {
        self.failure = failure
    }

    /// Holds each read, once it is recorded, until `gate` opens.
    func hold(using gate: ScriptedTransportCallGate?) {
        self.gate = gate
    }

    func read(_ request: HostProcessReader.Request) async throws -> [String: HostProcessReader.Facts] {
        requests.append(request)
        if let gate { await gate.waitUntilOpen() }
        if let failure { throw failure }
        var facts: [String: HostProcessReader.Facts] = [:]
        for pid in request.pids {
            facts[pid] = self.facts(for: pid, request)
        }
        if let root = request.descendantsOf, let rootPid = Int(root), processes[rootPid] != nil {
            var found: [String] = []
            var queue = [rootPid]
            while let next = queue.popLast() {
                let children = processes.values.filter { $0.parent == next }.map(\.pid).sorted()
                found += children.map(String.init)
                queue += children
            }
            for pid in found { facts[pid] = self.facts(for: pid, request) }
            facts[root]?.descendants = .value(found)
        }
        return facts
    }

    private func facts(for pid: String, _ request: HostProcessReader.Request) -> HostProcessReader.Facts {
        var fact = HostProcessReader.Facts()
        guard let number = Int(pid), let process = processes[number] else {
            for name in request.valuesOf { fact.variables[name] = .unavailable }
            return fact
        }
        fact.parent = String(process.parent)
        fact.name = process.name
        if request.readsStart { fact.start = .value(process.start) }
        for name in request.valuesOf {
            fact.variables[name] = process.environment[name].map(HostProcessReader.Variable.value) ?? .unset
        }
        if !request.namesOf.isEmpty {
            fact.nonEmptyNames = .value(
                Set(request.namesOf.filter { process.environment[$0]?.isEmpty == false }))
        }
        if request.readsOpenFiles { fact.openFiles = .value(process.openFiles) }
        if request.readsArguments {
            fact.arguments = .value(Set(request.argumentsAmong).intersection(process.argv))
            if request.preservesArgumentOrder, !process.argv.isEmpty {
                fact.argumentVector = .value(process.argv.map {
                    request.argumentsAmong.contains($0) ? $0 : $0.hasPrefix("-") ? "-" : ""
                })
            }
        }
        return fact
    }
}

/// Binding from what a Host shows about an Agent's own process (ADR 0034). The
/// registry entries take the fields Claude Code 2.1.288 and 2.1.314 wrote
/// (herdr compatibility, "Program Status from harnesses"): `sessions/<pid>.json`,
/// with a process start that is `/proc/<pid>/stat` field 22.
@Suite("herdr-core session binder")
struct HerdrCoreSessionBinderTests {
    private static let first = "e951205e-24af-4a5e-baa7-3ccbebd2de2c"
    private static let second = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"
    private static let scope = "scope-token-7"
    private static let home = "/home/dev"
    private static let baseEnvironment = ["HC_SCOPE": scope, "HOME": home]

    private static func claude(
        pid: Int = 4242, parent: Int = 1, name: String = "claude", start: String = "987654321",
        environment: [String: String] = [:]
    ) -> ScriptedProcessTable.Process {
        ScriptedProcessTable.Process(
            pid: pid, parent: parent, name: name, start: start,
            environment: baseEnvironment.merging(environment) { _, new in new })
    }

    private static func registryEntry(
        pid: Int = 4242, session: String = first, procStart: String = "987654321", cwd: String = "/work/app"
    ) -> Data {
        Data(
            """
            {"pid":\(pid),"sessionId":"\(session)","cwd":"\(cwd)","startedAt":1780000000000,\
            "procStart":"\(procStart)","version":"2.1.314","kind":"interactive","entrypoint":"cli",\
            "status":"idle","updatedAt":1780000000000}
            """.utf8)
    }

    private static func registryPath(pid: Int = 4242, root: String = "\(home)/.claude") -> String {
        "\(root)/sessions/\(pid).json"
    }

    static func record(
        pid: Int? = 4242, foreground: Int? = 4242, labels: [String: String] = [:]
    ) throws -> HerdrCoreTerminalRecord {
        let value = JSONValue.object([
            "address": .string("t7"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("claude")]), "keep": .bool(false), "title": .string(""),
            "cols": .number(80), "rows": .number(24), "name": .null,
            "pid": pid.map { .number(Double($0)) } ?? .null, "reason": .null,
            "labels": .object(labels.mapValues(JSONValue.string)),
            "foreground": foreground.map {
                .object([
                    "pid": .number(Double($0)), "name": .string("claude"),
                    "argv": .array([.string("claude")]), "cwd": .string("/work/app"),
                ])
            } ?? .null,
        ])
        return try JSONDecoder().decode(HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(value))
    }

    private actor LabelLog {
        var cleared: [[String]] = []
        var failure: TransportError?
        func clear(_ names: [String]) throws {
            cleared.append(names)
            if let failure { throw failure }
        }
        func setFailure(_ failure: TransportError?) { self.failure = failure }
    }

    private struct Rig {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: home)
        let labels = LabelLog()

        var binder: HerdrCoreSessionBinder {
            let table = table
            let labels = labels
            return HerdrCoreSessionBinder(
                program: .claude,
                processes: { try await table.read($0) },
                files: files.hostFiles(),
                clearLabels: { try await labels.clear($0.keys.sorted()) })
        }

        func add(_ process: ScriptedProcessTable.Process) async {
            await table.add(process)
        }

        /// Every path read, and how many of each kind of Host call a check cost.
        var reads: [String] {
            get async { await files.reads.map(\.path) }
        }
    }

    // MARK: Registry

    @Test func anAgentBindsFromTheEntryWhoseProcessStartMatches() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        let evidence = try await rig.binder.check(try Self.record())

        #expect(
            evidence == .bound(
                sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test func aMismatchedStartBindsNothing() async throws {
        let rig = Rig()
        await rig.add(Self.claude(start: "987654321"))
        await rig.files.write(Self.registryEntry(procStart: "111"), at: Self.registryPath())

        #expect(try await rig.binder.check(try Self.record()) == .unavailable(.cannotTellSession(.claude)))
    }

    @Test func anEntryForAnotherPidBindsNothing() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.files.write(Self.registryEntry(pid: 9), at: Self.registryPath())

        #expect(try await rig.binder.check(try Self.record()) == .unavailable(.cannotTellSession(.claude)))
    }

    @Test func aMissingEntryBindsNothingAndNoKeyFileIsEverRead() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        // What the folder holds before the prompt (2.1.314).
        let key = "\(Self.home)/.claude/sessions/4242.0123abcd.key"
        await rig.files.write(Data("secret".utf8), at: key)

        #expect(try await rig.binder.check(try Self.record()) == .unavailable(.cannotTellSession(.claude)))

        #expect(await rig.reads == [Self.registryPath()])
        #expect(await rig.files.listings.isEmpty)
    }

    @Test(arguments: ["not json", #"{"pid":4242}"#, #"{"pid":4242,"sessionId":"../x","procStart":"987654321"}"#])
    func anEntryThatDoesNotReadBindsNothing(_ text: String) async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.files.write(Data(text.utf8), at: Self.registryPath())

        #expect(try await rig.binder.check(try Self.record()) == .unavailable(.cannotTellSession(.claude)))
    }

    @Test func aRewrittenEntryRebindsToTheNewConversation() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.files.write(Self.registryEntry(session: Self.first), at: Self.registryPath())
        let before = try await rig.binder.check(try Self.record())

        // `/clear` and `/resume` rewrite the same file.
        await rig.files.write(Self.registryEntry(session: Self.second), at: Self.registryPath())
        let after = try await rig.binder.check(try Self.record())

        #expect(before == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
        #expect(after == .bound(sessionID: Self.second, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    // MARK: The walk

    @Test func theWalkReachesClaudeCodeBehindALauncherThroughDescendantsSharingTheScope() async throws {
        let rig = Rig()
        await rig.add(Self.claude(pid: 100, name: "npm"))
        await rig.add(Self.claude(pid: 101, parent: 100, name: "sh"))
        await rig.add(Self.claude(pid: 102, parent: 101, start: "555"))
        await rig.files.write(Self.registryEntry(pid: 102, procStart: "555"), at: Self.registryPath(pid: 102))

        let evidence = try await rig.binder.check(try Self.record(pid: 100, foreground: 100))

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
        #expect(await rig.reads == [Self.registryPath(pid: 102)])
    }

    @Test func aNodeLauncherWithTheSameNameLeadsToTheProcessItStarted() async throws {
        let rig = Rig()
        await rig.add(Self.claude(pid: 100))
        await rig.add(Self.claude(pid: 101, parent: 100, start: "555"))
        await rig.files.write(Self.registryEntry(pid: 101, procStart: "555"), at: Self.registryPath(pid: 101))

        let evidence = try await rig.binder.check(try Self.record(pid: 100, foreground: 100))

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test func aDescendantWithAnotherScopeIsNotFollowed() async throws {
        let rig = Rig()
        await rig.add(Self.claude(pid: 100, name: "npm"))
        await rig.add(Self.claude(pid: 101, parent: 100, environment: ["HC_SCOPE": "another-terminal"]))
        await rig.files.write(Self.registryEntry(pid: 101), at: Self.registryPath(pid: 101))

        let evidence = try await rig.binder.check(try Self.record(pid: 100, foreground: 100))

        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await !rig.reads.contains(Self.registryPath(pid: 101)))
    }

    @Test func theTerminalsOwnProcessSaysWhichScopeIsItsOwn() async throws {
        let rig = Rig()
        await rig.add(Self.claude(pid: 100, name: "zsh"))
        await rig.add(Self.claude(pid: 101, parent: 100, environment: ["HC_SCOPE": "another-terminal"]))
        await rig.files.write(Self.registryEntry(pid: 101), at: Self.registryPath(pid: 101))

        let evidence = try await rig.binder.check(try Self.record(pid: 100, foreground: 101))

        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await rig.reads.isEmpty)
    }

    @Test func aClaudeCodeThatAToolStartedIsNotTheAgent() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.add(Self.claude(pid: 200, parent: 4242, name: "bash"))
        await rig.add(
            Self.claude(pid: 201, parent: 200, start: "777", environment: ["CLAUDE_CODE_CHILD_SESSION": "1"]))
        await rig.add(
            Self.claude(pid: 202, parent: 4242, start: "888", environment: ["CLAUDE_CODE_CHILD_SESSION": "1"]))
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        let evidence = try await rig.binder.check(try Self.record())

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test func twoCandidatesAreNotGuessedBetween() async throws {
        let rig = Rig()
        await rig.add(Self.claude(pid: 100, name: "sh"))
        await rig.add(Self.claude(pid: 101, parent: 100))
        await rig.add(Self.claude(pid: 102, parent: 100))
        await rig.files.write(Self.registryEntry(pid: 101), at: Self.registryPath(pid: 101))

        let evidence = try await rig.binder.check(try Self.record(pid: 100, foreground: 100))

        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await rig.reads.isEmpty)
    }

    @Test func aWithheldForegroundRootIsNotWalkedIntoOnHerdrCore() async throws {
        let table = MacOSProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let scope = ["HC_SCOPE": Self.scope, "HOME": Self.home]
        await table.add(.init(pid: 100, name: "zsh", start: "987654321", environment: scope))
        await table.add(.init(pid: 200, parent: 100, name: "sh", start: "987654321", environment: scope))
        await table.withholdEnvironment(of: 200)
        await table.add(.init(pid: 201, parent: 200, name: "claude", start: "987654321", environment: scope))
        await files.write(Self.registryEntry(pid: 201), at: Self.registryPath(pid: 201))

        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { try await table.read($0) },
            files: files.hostFiles(),
            clearLabels: { _ in },
            hostSystem: .macOS)

        let evidence = try await binder.check(try Self.record(pid: 100, foreground: 200))
        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await files.reads.isEmpty)
    }

    @Test func aCodexForegroundWithOmittedArgvDoesNotAssumeTheSharedDaemon() async throws {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: Self.home)
        let scope = ["HC_SCOPE": Self.scope, "HOME": Self.home]
        await table.add(.init(pid: 4242, name: "codex", start: "987654321", environment: scope))
        await files.write(
            Data("sock".utf8),
            at: CodexLaunch.controlSocketPath(home: Self.home))
        let recordValue = JSONValue.object([
            "address": .string("t1"),
            "cwd": .string("/work/app"),
            "state": .string("live"),
            "argv": .array([.string("codex")]),
            "keep": .bool(false),
            "title": .string(""),
            "cols": .number(80),
            "rows": .number(24),
            "pid": .number(4242),
            "foreground": .object([
                "pid": .number(4242),
                "name": .string("codex"),
                "cwd": .string("/work/app"),
            ]),
        ])
        let decoded = try JSONDecoder().decode(
            HerdrCoreTerminalRecord.self, from: JSONEncoder().encode(recordValue))
        #expect(decoded.foreground?.argv == [])

        let binder = HerdrCoreSessionBinder(
            program: .codex,
            processes: { try await table.read($0) },
            files: files.hostFiles(),
            clearLabels: { _ in })

        #expect(try await binder.check(decoded) == .unavailable(.cannotTellSession(.codex)))
        guard case .listed(let listed) = try await binder.candidates(of: decoded) else {
            Issue.record("Expected listed candidates instead of sharedDaemon")
            return
        }
        #expect(listed.pid == 4242)
    }

    @Test func aForegroundWithAnotherNameAndNothingUnderItIsTheProcess() async throws {
        let rig = Rig()
        // The Agent rule named it from its arguments: `node .../cli.js`.
        await rig.add(Self.claude(name: "node"))
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        let evidence = try await rig.binder.check(try Self.record())

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test func aTreeTooLargeToReadStillBindsAForegroundThatIsClaudeCode() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())
        let table = rig.table
        let binder = HerdrCoreSessionBinder(
            program: .claude,
            processes: { request in
                var facts = try await table.read(request)
                facts["4242"]?.descendants = .unavailable
                return facts
            },
            files: rig.files.hostFiles(), clearLabels: { _ in })

        #expect(try await binder.check(try Self.record()) == .bound(
            sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test(arguments: [(pid: Int?.none, foreground: Int?.some(4242)), (pid: 4242, foreground: nil)])
    func aTerminalWithoutAProcessToStartFromCanTellNothing(_ processes: (pid: Int?, foreground: Int?)) async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        let evidence = try await rig.binder.check(
            try Self.record(pid: processes.pid, foreground: processes.foreground))

        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await rig.table.requests.isEmpty)
    }

    @Test func herdrVariablesInTheEvidenceAreIgnored() async throws {
        let rig = Rig()
        await rig.add(
            Self.claude(environment: [
                "HERDR_ENV": "1", "HERDR_PANE_ID": "w1:1", "HERDR_SOCKET_PATH": "/x",
                "HERDR_AGENT_SESSION": Self.second,
            ]))

        let evidence = try await rig.binder.check(try Self.record())

        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        let request = try #require(await rig.table.requests.first)
        let asked = request.valuesOf + request.namesOf + request.namesWithPrefix
        #expect(!asked.contains { $0.hasPrefix("HERDR") })
    }

    @Test func itAsksForTheVariablesItNamesAndNoOthers() async throws {
        let rig = Rig()
        await rig.add(Self.claude())

        _ = try await rig.binder.check(try Self.record())

        let request = try #require(await rig.table.requests.first)
        #expect(Set(request.valuesOf) == ["HC_SCOPE", "HOME", "CLAUDE_CONFIG_DIR"])
        #expect(Set(request.namesOf) == ["CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SKIP_PROMPT_HISTORY"])
        #expect(request.namesWithPrefix.isEmpty)
        #expect(request.descendantsOf == "4242")
    }

    // MARK: Config dir

    @Test func theRootComesFromTheAgentsOwnConfigDir() async throws {
        let rig = Rig()
        await rig.add(Self.claude(environment: ["CLAUDE_CONFIG_DIR": "/srv/work account"]))
        await rig.files.write(Self.registryEntry(), at: Self.registryPath(root: "/srv/work account"))
        // The Host's Default Account has one too, for another conversation.
        await rig.files.write(Self.registryEntry(session: Self.second), at: Self.registryPath())

        #expect(try await rig.binder.check(try Self.record()) == .bound(
            sessionID: Self.first, transcriptRoot: "/srv/work account", directory: "/work/app"))
        #expect(await rig.reads == [Self.registryPath(root: "/srv/work account")])
    }

    @Test(arguments: ["", "relative/dir", "/a/../b", "~/x"])
    func aConfigDirThatNamesNoPlaceBindsNothing(_ value: String) async throws {
        let rig = Rig()
        await rig.add(Self.claude(environment: ["CLAUDE_CONFIG_DIR": value]))
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        #expect(try await rig.binder.check(try Self.record()) == .unavailable(.cannotTellSession(.claude)))
        #expect(await rig.reads.isEmpty)
    }

    // MARK: Leaked variables

    @Test(arguments: [
        ("CLAUDE_CODE_CHILD_SESSION", ChatTranscriptOffVariable.childSession),
        ("CLAUDE_CODE_SKIP_PROMPT_HISTORY", ChatTranscriptOffVariable.skipPromptHistory),
    ])
    func aVariableThatStopsTheTranscriptIsTheReason(_ name: String, _ variable: ChatTranscriptOffVariable) async throws {
        let rig = Rig()
        await rig.add(Self.claude(environment: [name: "1"]))
        // With `=1` Claude Code 2.1.316 kept no entry under the child-session marker,
        // and one beside a skipped history, with no Transcript (#579).
        if variable == .skipPromptHistory {
            await rig.files.write(Self.registryEntry(), at: Self.registryPath())
        }

        let alone = try await rig.binder.check(try Self.record())
        let shared = try await rig.binder.check(try Self.record(), coreCarries: [name])

        #expect(alone == .unavailable(.transcriptOff(variable, coreCarriesIt: false)))
        #expect(shared == .unavailable(.transcriptOff(variable, coreCarriesIt: true)))
    }

    /// Claude Code 2.1.316 ignored `CLAUDE_CODE_CHILD_SESSION=made-up` and kept its
    /// entry and Transcript, so Chat follows them rather than saying they are off.
    @Test func aChildSessionClaudeCodeIgnoredBindsByItsEntry() async throws {
        let rig = Rig()
        await rig.add(Self.claude(environment: ["CLAUDE_CODE_CHILD_SESSION": "made-up"]))
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        let evidence = try await rig.binder.check(try Self.record(), coreCarries: ["CLAUDE_CODE_CHILD_SESSION"])

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test func aBlankVariableReadsAsUnset() async throws {
        let rig = Rig()
        await rig.add(Self.claude(environment: ["CLAUDE_CODE_CHILD_SESSION": "", "CLAUDE_CODE_SKIP_PROMPT_HISTORY": ""]))
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        #expect(try await rig.binder.check(try Self.record()) == .bound(
            sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    // MARK: Hints

    fileprivate static func hint(session: String = first, pid: Int = 4242, start: String? = "987654321") -> String {
        let startField = start.map { #","start":"\#($0)""# } ?? ""
        return #"{"session":"\#(session)","pid":\#(pid)\#(startField)}"#
    }

    @Test(arguments: ["heeler.session", "heeler.chat"])
    func aHintIsAdoptedWhenItsPidAndStartMatchTheResolvedProcess(_ label: String) async throws {
        let rig = Rig()
        await rig.add(Self.claude())

        let evidence = try await rig.binder.check(try Self.record(labels: [label: Self.hint()]))

        let root = "\(Self.home)/.claude"
        #expect(
            evidence == (label == "heeler.chat"
                ? .picked(sessionID: Self.first, transcriptRoot: root)
                : .bound(sessionID: Self.first, transcriptRoot: root, directory: nil)))
        #expect(await rig.labels.cleared.isEmpty)
    }

    @Test func theRegistryEntryWinsOverAMatchingHint() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.files.write(Self.registryEntry(session: Self.second), at: Self.registryPath())

        let evidence = try await rig.binder.check(
            try Self.record(labels: ["heeler.chat": Self.hint(session: Self.first)]))

        #expect(evidence == .bound(sessionID: Self.second, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test(arguments: [
        HerdrCoreSessionBinderTests.hint(pid: 9), HerdrCoreSessionBinderTests.hint(start: "111"),
        HerdrCoreSessionBinderTests.hint(start: nil), "not json", #"{"session":"x"}"#,
    ])
    func aStaleHintIsNotAdoptedAndIsCleared(_ value: String) async throws {
        let rig = Rig()
        await rig.add(Self.claude())

        let evidence = try await rig.binder.check(try Self.record(labels: ["heeler.session": value]))

        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await rig.labels.cleared == [["heeler.session"]])
    }

    /// The record is what the check began on. What counts is what stands once the
    /// exec has said which process this is.
    @Test func aHintWrittenDuringTheExecIsAdoptedAndTheEarlierOneNotCleared() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        var binder = rig.binder
        binder.currentLabels = { ["heeler.session": Self.hint()] }

        let evidence = try await binder.check(try Self.record(labels: ["heeler.session": Self.hint(pid: 9)]))

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: nil))
        #expect(await rig.labels.cleared.isEmpty)
    }

    @Test func aHintWhoseSessionIsNotAnIdIsNotAdopted() async throws {
        let rig = Rig()
        await rig.add(Self.claude())

        let evidence = try await rig.binder.check(
            try Self.record(labels: ["heeler.session": Self.hint(session: "../../etc/passwd")]))

        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
    }

    @Test func aHintFailingToClearChangesNothing() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.labels.setFailure(.cancelled)
        await rig.files.write(Self.registryEntry(), at: Self.registryPath())

        let evidence = try await rig.binder.check(try Self.record(labels: ["heeler.chat": Self.hint(pid: 9)]))

        #expect(evidence == .bound(sessionID: Self.first, transcriptRoot: "\(Self.home)/.claude", directory: "/work/app"))
    }

    @Test func aHintIsLeftAloneWhileNoProcessCanBeResolved() async throws {
        let rig = Rig()
        await rig.add(Self.claude(environment: ["HC_SCOPE": ""]))

        let evidence = try await rig.binder.check(try Self.record(labels: ["heeler.chat": Self.hint(pid: 9)]))

        #expect(evidence == .pickUnconfirmed(.cannotTellSession(.claude)))
        #expect(await rig.labels.cleared.isEmpty)
    }

    @Test func theLaunchLabelIsNoHint() async throws {
        let rig = Rig()
        await rig.add(Self.claude())

        let evidence = try await rig.binder.check(
            try Self.record(labels: [HerdrCoreLaunch.sessionHintLabel: Self.first]))

        // It names no process, so nothing ties it to this one, and it stays.
        #expect(evidence == .unavailable(.cannotTellSession(.claude)))
        #expect(await rig.labels.cleared.isEmpty)
    }

    // MARK: Cost

    @Test func aCheckCostsAtMostOneExecAndOneRead() async throws {
        let rig = Rig()
        await rig.add(Self.claude(pid: 100, name: "npm"))
        await rig.add(Self.claude(pid: 101, parent: 100, start: "555"))
        await rig.files.write(Self.registryEntry(pid: 101, procStart: "555"), at: Self.registryPath(pid: 101))

        _ = try await rig.binder.check(
            try Self.record(pid: 100, foreground: 100, labels: ["heeler.session": Self.hint(pid: 9)]))

        #expect(await rig.table.requests.count == 1)
        #expect(await rig.reads.count == 1)
        #expect(await rig.files.statuses.isEmpty)
        #expect(await rig.files.listings.isEmpty)
    }

    @Test func aFailedExecReadsNoFileAndSaysSo() async throws {
        let rig = Rig()
        await rig.add(Self.claude())
        await rig.table.setFailure(.sshUnreachable(detail: "gone"))

        await #expect(throws: TransportError.self) {
            _ = try await rig.binder.check(try Self.record())
        }
        #expect(await rig.reads.isEmpty)
    }

    // MARK: The read over SSH

    private static let readRequest = HostProcessReader.Request(pids: ["100"], descendantsOf: "100")

    private static func transport(on host: ScriptedCoreHost) -> HerdrCoreSSHTransport {
        HerdrCoreSSHTransport(connection: host, session: "x", nonce: { ScriptedCoreHost.nonce })
    }

    @Test func aHostThatCannotAnswerShowsNothingAndCostsOneExec() async throws {
        for read in [
            ScriptedCoreHost.ProcessRead.exits(status: 1, stdout: ""),
            .exits(status: 0, stdout: "not what the reader prints"),
        ] {
            let host = ScriptedCoreHost(processRead: read, channel: .core(.init()))

            let facts = try await Self.transport(on: host).readProcesses(Self.readRequest)

            #expect(facts.isEmpty)
            #expect(await host.log == ["process-read"])
        }
    }

    @Test func aLostLinkIsAnErrorRatherThanAnEmptyTable() async throws {
        let host = ScriptedCoreHost(
            processRead: .throwsError(.sshUnreachable(detail: "gone")), channel: .core(.init()))

        await #expect(throws: TransportError.self) {
            _ = try await Self.transport(on: host).readProcesses(Self.readRequest)
        }
    }
}
