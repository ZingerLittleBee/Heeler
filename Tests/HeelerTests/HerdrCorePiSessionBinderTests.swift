import Foundation
import Testing

@testable import Heeler

/// Binding Pi and Oh My Pi from what a Host shows of them (ADR 0034), over the
/// recordings in `ChatFixtures/host-evidence`. The extension's label is not in
/// them, since no recording ran the extension, so it takes the shape
/// `plugin/helper/extensions/heeler-session.js` writes.
@Suite("herdr-core Pi and Oh My Pi session binder")
struct HerdrCorePiSessionBinderTests {
    private actor LabelLog {
        var cleared: [[String]] = []
        func clear(_ names: [String]) { cleared.append(names) }
    }

    private struct Rig {
        let table = ScriptedProcessTable()
        let files = VirtualHostFiles(home: "/home/core")
        let labels = LabelLog()

        func binder(_ program: ChatProgram) -> HerdrCoreSessionBinder {
            let table = table
            let labels = labels
            return HerdrCoreSessionBinder(
                program: program,
                processes: { try await table.read($0) },
                files: files.hostFiles(),
                clearLabels: { await labels.clear($0.keys.sorted()) })
        }

        /// The processes of one recorded scene. A name holding anything else reads
        /// as `-`, as the reader prints it.
        func add(
            _ scene: PiHostEvidence.Scene, environment: [String: String] = [:],
            filesOf extra: [Int: [String]] = [:]
        ) async {
            for process in scene.processes {
                let readable = process.name.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
                await table.add(
                    ScriptedProcessTable.Process(
                        pid: process.pid, parent: process.parent, name: readable ? process.name : "-",
                        start: process.start,
                        environment: process.environment.merging(environment) { $1 },
                        openFiles: process.files + (extra[process.pid] ?? [])))
            }
        }

        var reads: [String] {
            get async { await files.reads.map(\.path) }
        }
    }

    private static func label(session: String, file: String? = nil, pid: Int, start: String?) -> String {
        let fileField = file.map { #","file":"\#($0)""# } ?? ""
        let startField = start.map { #","start":"\#($0)""# } ?? ""
        return #"{"session":"\#(session)"\#(fileField),"pid":\#(pid)\#(startField)}"#
    }

    // MARK: Pi

    private static let otherSession = "0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11"

    /// One Pi run as recorded, at its prompt.
    private struct PiRun {
        let evidence: PiHostEvidence
        let events: String
        let process: PiHostEvidence.Process
        let id: String
        let file: String
        let agentDir: String
        var sessions: String { "\(agentDir)/sessions" }
        var environment: [String: String] { ["PI_CODING_AGENT_DIR": agentDir, "HOME": "/home/agent"] }

        init(version: String) throws {
            let evidence = try PiHostEvidence.load("pi/session-files-\(version).json")
            let process = try #require(try evidence.scene("at-prompt").processes.first)
            let id = try #require(evidence.launchId)
            let file = try #require(evidence.sessionFile(id: id))
            let agentDir = try #require(file.components(separatedBy: "/sessions/").first)
            self.evidence = evidence
            self.events = "pi/session-files-\(version)-core-events.ndjson"
            self.process = process
            self.id = id
            self.file = file
            self.agentDir = agentDir
        }

        func record(argv: [String]? = nil, labels: [String: String] = [:]) throws -> HerdrCoreTerminalRecord {
            try PiHostEvidence.terminal(events: events, foregroundPid: process.pid, argv: argv, labels: labels)
        }

        func addScene(to rig: Rig) async throws {
            await rig.add(try evidence.scene("at-prompt"), environment: environment)
        }

        var launch: [String] { ["/usr/bin/fish", "-ic", "exec $argv[2..]", "fish", "pi", "--session-id", id] }
    }

    private static let piVersions = ["0.85.1", "1.4.0"]

    @Test(arguments: piVersions)
    func anExtensionLabelBindsPiWhenItsPidAndStartMatch(_ version: String) async throws {
        let run = try PiRun(version: version)
        let rig = Rig()
        try await run.addScene(to: rig)
        let label = Self.label(session: run.id, file: run.file, pid: run.process.pid, start: run.process.start)

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: run.file, transcriptRoot: run.sessions, directory: nil))
        #expect(await rig.labels.cleared.isEmpty)
    }

    @Test(arguments: piVersions)
    func aPiLabelForAnotherProcessBindsNothingAndIsCleared(_ version: String) async throws {
        let run = try PiRun(version: version)
        for (pid, start) in [(9, run.process.start), (run.process.pid, "1"), (run.process.pid, nil)] {
            let rig = Rig()
            try await run.addScene(to: rig)
            let label = Self.label(session: run.id, file: run.file, pid: pid, start: start)

            let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

            #expect(evidence == .unavailable(.cannotTellSession(.pi)))
            #expect(await rig.labels.cleared == [["heeler.session"]])
        }
    }

    @Test func aLabelWithNoFileBindsItsIdUnderTheAgentsOwnRoot() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        try await run.addScene(to: rig)
        let label = Self.label(session: run.id, pid: run.process.pid, start: run.process.start)

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: run.id, transcriptRoot: run.sessions, directory: nil))
    }

    @Test(arguments: [
        "/elsewhere/2026_0a4a7c8e-7a53-4f0e-8a7e-0d7a4b1f9c11.jsonl", "/elsewhere/a.txt", "relative.jsonl",
        "/a/../b_00000000-0000-4000-8000-000000000001.jsonl",
    ])
    func aLabelWhoseFileIsNotItsSessionsBindsNothing(_ file: String) async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        try await run.addScene(to: rig)
        let label = Self.label(session: run.id, file: file, pid: run.process.pid, start: run.process.start)

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
    }

    @Test func aRewrittenLabelRebindsPi() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        try await run.addScene(to: rig)
        let afterNew = try #require(run.evidence.sessionFiles.keys.first { $0 != run.file })
        let newID = try #require(run.evidence.sessionFiles[afterNew]?.header.id)
        func label(_ id: String, _ file: String) -> [String: String] {
            ["heeler.session": Self.label(session: id, file: file, pid: run.process.pid, start: run.process.start)]
        }

        let before = try await rig.binder(.pi).check(try run.record(labels: label(run.id, run.file)))
        let after = try await rig.binder(.pi).check(try run.record(labels: label(newID, afterNew)))

        #expect(before == .bound(sessionID: run.file, transcriptRoot: run.sessions, directory: nil))
        #expect(after == .bound(sessionID: afterNew, transcriptRoot: run.sessions, directory: nil))
    }

    // MARK: Pi's launch hint

    @Test(arguments: piVersions)
    func aLaunchHintBindsPiBeforeAnyExtensionLabelExists(_ version: String) async throws {
        let run = try PiRun(version: version)
        let rig = Rig()
        try await run.addScene(to: rig)

        let evidence = try await rig.binder(.pi).check(
            try run.record(argv: run.launch, labels: [HerdrCoreLaunch.sessionHintLabel: run.id]))

        #expect(evidence == .bound(sessionID: run.id, transcriptRoot: run.sessions, directory: nil))
        #expect(await rig.labels.cleared.isEmpty)
    }

    @Test func aMatchingExtensionLabelWinsOverTheLaunchHint() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        try await run.addScene(to: rig)
        let afterNew = try #require(run.evidence.sessionFiles.keys.first { $0 != run.file })
        let newID = try #require(run.evidence.sessionFiles[afterNew]?.header.id)

        let evidence = try await rig.binder(.pi).check(
            try run.record(
                argv: run.launch,
                labels: [
                    HerdrCoreLaunch.sessionHintLabel: run.id,
                    "heeler.session": Self.label(
                        session: newID, file: afterNew, pid: run.process.pid, start: run.process.start),
                ]))

        #expect(evidence == .bound(sessionID: afterNew, transcriptRoot: run.sessions, directory: nil))
    }

    @Test func aStaleLabelLeavesTheLaunchHintToBind() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        try await run.addScene(to: rig)

        let evidence = try await rig.binder(.pi).check(
            try run.record(
                argv: run.launch,
                labels: [
                    HerdrCoreLaunch.sessionHintLabel: run.id,
                    "heeler.session": Self.label(session: Self.otherSession, pid: 9, start: "1"),
                ]))

        #expect(evidence == .bound(sessionID: run.id, transcriptRoot: run.sessions, directory: nil))
        #expect(await rig.labels.cleared == [["heeler.session"]])
    }

    /// `hc run` and a Template write no launch label, whatever their arguments say.
    @Test func pisArgumentsAloneBindNothing() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        try await run.addScene(to: rig)

        let evidence = try await rig.binder(.pi).check(try run.record(argv: ["pi", "--session-id", run.id]))

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
    }

    /// `restarted` replaces a kept Terminal's arguments and leaves its labels.
    @Test func aLaunchLabelTheArgumentsNoLongerCarryBindsNothing() async throws {
        let run = try PiRun(version: "1.4.0")
        for argv in [["/bin/zsh"], ["pi", "--session-id", Self.otherSession], ["pi", run.id, "--session-id"]] {
            let rig = Rig()
            try await run.addScene(to: rig)

            let evidence = try await rig.binder(.pi).check(
                try run.record(argv: argv, labels: [HerdrCoreLaunch.sessionHintLabel: run.id]))

            #expect(evidence == .unavailable(.cannotTellSession(.pi)))
        }
    }

    /// The arguments are the Terminal's first process's, so they say nothing of a
    /// Pi another process started under it.
    @Test func aLaunchHintSpeaksOnlyForTheTerminalsOwnProcess() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        let scope = try #require(run.process.environment["HC_SCOPE"])
        let environment = run.environment.merging(["HC_SCOPE": scope]) { $1 }
        await rig.table.add(.init(pid: 100, name: "sh", start: "5", environment: environment))
        await rig.table.add(.init(pid: 101, parent: 100, name: "pi", start: "6", environment: environment))
        let record = try PiHostEvidence.terminal(
            events: run.events, foregroundPid: run.process.pid, argv: run.launch,
            labels: [HerdrCoreLaunch.sessionHintLabel: run.id])
        var launcher = record
        launcher.pid = 100
        launcher.foreground = HerdrCoreForeground(pid: 100, name: "sh", argv: ["sh"], cwd: "/")

        let evidence = try await rig.binder(.pi).check(launcher)

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
    }

    // MARK: Without exact evidence

    @Test(arguments: piVersions)
    func piWithNoEvidenceBindsNothingAndLooksAtNoFile(_ version: String) async throws {
        let run = try PiRun(version: version)
        let rig = Rig()
        try await run.addScene(to: rig)
        // The newest Transcript in the Agent's directory, for the taking.
        await rig.files.write(Data(#"{"type":"session","version":3,"id":"x"}"#.utf8), at: run.file)

        let evidence = try await rig.binder(.pi).check(try run.record())

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
        #expect(await rig.reads.isEmpty)
        #expect(await rig.files.listings.isEmpty)
        #expect(await rig.files.statuses.isEmpty)
    }

    @Test(arguments: [ChatProgram.pi, .omp])
    func herdrVariablesAreNeitherAskedForNorBelieved(_ program: ChatProgram) async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        await rig.table.add(
            .init(
                pid: run.process.pid, name: program.rawValue, start: run.process.start,
                environment: run.process.environment.merging([
                    "HOME": "/home/agent", "HERDR_ENV": "1", "HERDR_PANE_ID": "w1:1",
                    "HERDR_AGENT_SESSION": Self.otherSession,
                ]) { $1 }))

        let evidence = try await rig.binder(program).check(try run.record())

        #expect(evidence == .unavailable(.cannotTellSession(program)))
        let request = try #require(await rig.table.requests.first)
        #expect(!(request.valuesOf + request.namesOf + request.namesWithPrefix).contains { $0.hasPrefix("HERDR") })
    }

    @Test func itAsksForTheVariablesItNamesAndNoOthers() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        try await run.addScene(to: rig)

        _ = try await rig.binder(.pi).check(try run.record())
        _ = try await rig.binder(.omp).check(try run.record())

        let requests = await rig.table.requests
        #expect(
            Set(requests[0].valuesOf) == ["HC_SCOPE", "HOME", "PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR"])
        #expect(!requests[0].readsOpenFiles)
        #expect(
            Set(requests[1].valuesOf)
                == ["HC_SCOPE", "HOME", "PI_CODING_AGENT_DIR", "PI_CONFIG_DIR", "OMP_PROFILE", "PI_PROFILE"])
        #expect(requests[1].readsOpenFiles)
        for request in requests {
            #expect(request.namesOf.isEmpty)
            #expect(request.namesWithPrefix.isEmpty)
        }
    }

    // MARK: The process

    @Test func aForegroundWithAnotherNameIsNoAgentAndItsLabelStays() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        await rig.table.add(
            .init(
                pid: run.process.pid, name: "vim", start: run.process.start,
                environment: run.process.environment.merging(run.environment) { $1 }))
        let label = Self.label(session: run.id, file: run.file, pid: 9, start: "1")

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
        #expect(await rig.labels.cleared.isEmpty)
    }

    @Test func aDescendantOutsideTheScopeIsNotFollowed() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        let scope = try #require(run.process.environment["HC_SCOPE"])
        await rig.table.add(
            .init(pid: run.process.pid, name: "npm", start: "1", environment: ["HC_SCOPE": scope, "HOME": "/home/agent"]))
        await rig.table.add(
            .init(
                pid: 500, parent: run.process.pid, name: "pi", start: "2",
                environment: ["HC_SCOPE": "another-terminal", "HOME": "/home/agent"]))
        let label = Self.label(session: run.id, file: run.file, pid: 500, start: "2")

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
    }

    @Test func twoEquallyNearPisAreNotGuessedBetween() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        let environment = run.process.environment.merging(run.environment) { $1 }
        await rig.table.add(.init(pid: run.process.pid, name: "sh", start: "1", environment: environment))
        await rig.table.add(.init(pid: 501, parent: run.process.pid, name: "pi", start: "2", environment: environment))
        await rig.table.add(.init(pid: 502, parent: run.process.pid, name: "pi", start: "3", environment: environment))
        let label = Self.label(session: run.id, file: run.file, pid: 501, start: "2")

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
    }

    @Test func piBehindALauncherIsReached() async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        let environment = run.process.environment.merging(run.environment) { $1 }
        await rig.table.add(.init(pid: run.process.pid, name: "npm", start: "1", environment: environment))
        await rig.table.add(.init(pid: 501, parent: run.process.pid, name: "pi", start: "2", environment: environment))
        let label = Self.label(session: run.id, file: run.file, pid: 501, start: "2")

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: run.file, transcriptRoot: run.sessions, directory: nil))
    }

    // MARK: Roots

    @Test(arguments: [
        ([String: String](), "/home/agent/.pi/agent/sessions"),
        (["PI_CODING_AGENT_DIR": "/srv/pi"], "/srv/pi/sessions"),
        (["PI_CODING_AGENT_DIR": "/srv/pi/"], "/srv/pi/sessions"),
        (["PI_CODING_AGENT_DIR": ""], "/home/agent/.pi/agent/sessions"),
        (["PI_CODING_AGENT_DIR": "~/pi"], "/home/agent/pi/sessions"),
        (["PI_CODING_AGENT_DIR": "/srv/pi", "PI_CODING_AGENT_SESSION_DIR": "/srv/flat"], "/srv/flat"),
        (["PI_CODING_AGENT_SESSION_DIR": "~/flat"], "/home/agent/flat"),
        (["PI_CODING_AGENT_SESSION_DIR": ""], "/home/agent/.pi/agent/sessions"),
    ])
    func pisRootComesFromItsOwnEnvironment(_ environment: [String: String], _ root: String) async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        await rig.add(
            try run.evidence.scene("at-prompt"), environment: ["HOME": "/home/agent"].merging(environment) { $1 })
        let label = Self.label(session: run.id, pid: run.process.pid, start: run.process.start)

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: run.id, transcriptRoot: root, directory: nil))
    }

    @Test(arguments: [
        ["PI_CODING_AGENT_DIR": "relative/dir"], ["PI_CODING_AGENT_DIR": "/a/../b"],
        ["PI_CODING_AGENT_SESSION_DIR": "relative"],
    ])
    func aRootThatNamesNoPlaceBindsNothing(_ environment: [String: String]) async throws {
        let run = try PiRun(version: "1.4.0")
        let rig = Rig()
        await rig.add(
            try run.evidence.scene("at-prompt"), environment: ["HOME": "/home/agent"].merging(environment) { $1 })
        let label = Self.label(session: run.id, pid: run.process.pid, start: run.process.start)

        let evidence = try await rig.binder(.pi).check(try run.record(labels: ["heeler.session": label]))

        #expect(evidence == .unavailable(.cannotTellSession(.pi)))
    }

    @Test(arguments: [
        ([String: String](), "/home/agent/.omp/agent/sessions"),
        (["PI_CONFIG_DIR": ".config/omp"], "/home/agent/.config/omp/agent/sessions"),
        (["PI_CODING_AGENT_DIR": "/srv/omp"], "/srv/omp/sessions"),
        (["OMP_PROFILE": "work"], "/home/agent/.omp/profiles/work/agent/sessions"),
        (["PI_PROFILE": "work"], "/home/agent/.omp/profiles/work/agent/sessions"),
        (["OMP_PROFILE": "", "PI_PROFILE": "work"], "/home/agent/.omp/agent/sessions"),
        (["OMP_PROFILE": "default"], "/home/agent/.omp/agent/sessions"),
        (["OMP_PROFILE": "work", "PI_CODING_AGENT_DIR": "/srv/omp"], "/home/agent/.omp/profiles/work/agent/sessions"),
    ])
    func oMPsRootComesFromItsOwnEnvironment(_ environment: [String: String], _ root: String) async throws {
        let recording = try PiHostEvidence.load("omp/breadcrumb-and-session-files.json")
        let process = try #require(try recording.scene("at-prompt").processes.first)
        let rig = Rig()
        await rig.add(
            try recording.scene("at-prompt"), environment: ["HOME": "/home/agent"].merging(environment) { $1 })
        let label = Self.label(session: Self.otherSession, pid: process.pid, start: process.start)

        let evidence = try await rig.binder(.omp).check(
            try PiHostEvidence.terminal(
                events: "omp/breadcrumb-core-events.ndjson", foregroundPid: process.pid,
                labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: Self.otherSession, transcriptRoot: root, directory: nil))
    }

    @Test(arguments: [["OMP_PROFILE": "Not Valid"], ["PI_CONFIG_DIR": "../up"], ["PI_CODING_AGENT_DIR": "~/x"]])
    func anOMPRootThatNamesNoPlaceBindsNothing(_ environment: [String: String]) async throws {
        let recording = try PiHostEvidence.load("omp/breadcrumb-and-session-files.json")
        let process = try #require(try recording.scene("at-prompt").processes.first)
        let rig = Rig()
        await rig.add(
            try recording.scene("at-prompt"), environment: ["HOME": "/home/agent"].merging(environment) { $1 })
        let label = Self.label(session: Self.otherSession, pid: process.pid, start: process.start)

        let evidence = try await rig.binder(.omp).check(
            try PiHostEvidence.terminal(
                events: "omp/breadcrumb-core-events.ndjson", foregroundPid: process.pid,
                labels: ["heeler.session": label]))

        #expect(evidence == .unavailable(.cannotTellSession(.omp)))
    }

    // MARK: Oh My Pi

    /// One Oh My Pi run as recorded. Its first file is the one `at-prompt` names.
    private struct OMPRun {
        static let events = "omp/breadcrumb-core-events.ndjson"
        static let home = "/home/user/lab/iso/omp/home"
        static let agentDir = "\(home)/.omp/agent"
        let evidence: PiHostEvidence
        let terminal: String
        var crumbPath: String { "\(Self.agentDir)/terminal-sessions/\(terminal)" }
        var sessions: String { "\(Self.agentDir)/sessions" }
        /// The recording lists only the session files a process holds: its
        /// terminal is what `/proc/<pid>/fd/0` reads (Oh My Pi's `getTtyPath`).
        var tty: String { "/dev/\(terminal.replacingOccurrences(of: "-", with: "/"))" }

        init() throws {
            let evidence = try PiHostEvidence.load("omp/breadcrumb-and-session-files.json")
            let terminal = try #require(evidence.breadcrumbs?.terminal)
            self.evidence = evidence
            self.terminal = terminal
        }

        func agent(in scene: String) throws -> PiHostEvidence.Process {
            try #require(try evidence.scene(scene).processes.first)
        }

        func set(rig: Rig, scene: String, crumb: String?) async throws {
            let process = try agent(in: scene)
            await rig.add(
                try evidence.scene(scene), environment: ["HOME": Self.home], filesOf: [process.pid: [tty]])
            if let crumb { await rig.files.write(try evidence.breadcrumb(crumb), at: crumbPath) }
        }

        func record(scene: String, labels: [String: String] = [:]) throws -> HerdrCoreTerminalRecord {
            try PiHostEvidence.terminal(
                events: Self.events, foregroundPid: try agent(in: scene).pid, labels: labels)
        }

        /// The session file a recorded breadcrumb names, its second line.
        func namedFile(_ crumb: String) throws -> String {
            let text = String(decoding: try evidence.breadcrumb(crumb), as: UTF8.self)
            return text.components(separatedBy: "\n")[1]
        }
    }

    @Test func anExtensionLabelBindsOMPWhenItsPidAndStartMatch() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "at-prompt", crumb: "at-prompt")
        let process = try run.agent(in: "at-prompt")
        let file = try run.namedFile("at-prompt")
        let id = try #require(run.evidence.sessionFiles[file]?.header.id)
        let label = Self.label(session: id, file: file, pid: process.pid, start: process.start)

        let evidence = try await rig.binder(.omp).check(
            try run.record(scene: "at-prompt", labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: file, transcriptRoot: run.sessions, directory: nil))
        #expect(await rig.reads.isEmpty)
    }

    @Test func anOMPLabelForAnotherProcessFallsToItsBreadcrumbAndIsCleared() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "after-first-reply", crumb: "after-first-reply")
        let file = try run.namedFile("after-first-reply")
        let label = Self.label(session: Self.otherSession, pid: 9, start: "1")

        let evidence = try await rig.binder(.omp).check(
            try run.record(scene: "after-first-reply", labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: file, transcriptRoot: run.sessions, directory: nil))
        #expect(await rig.labels.cleared == [["heeler.session"]])
    }

    @Test func aBreadcrumbTheProcessHoldsOpenBindsOMP() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "after-first-reply", crumb: "after-first-reply")

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "after-first-reply"))

        #expect(
            evidence == .bound(
                sessionID: try run.namedFile("after-first-reply"), transcriptRoot: run.sessions, directory: nil))
        #expect(await rig.reads == [run.crumbPath])
        #expect(await rig.table.requests.count == 1)
        #expect(await rig.files.statuses.isEmpty)
        #expect(await rig.files.listings.isEmpty)
    }

    @Test func aBreadcrumbFollowsNewWhenTheProcessMovesToItsFile() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "after-new", crumb: "after-new")

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "after-new"))

        #expect(
            evidence == .bound(sessionID: try run.namedFile("after-new"), transcriptRoot: run.sessions, directory: nil))
    }

    /// At its prompt the breadcrumb names a file that does not exist yet.
    @Test func aBreadcrumbBeforeTheFirstMessageBindsNothing() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "at-prompt", crumb: "at-prompt")

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "at-prompt"))

        #expect(evidence == .unavailable(.cannotTellSession(.omp)))
    }

    /// The file exists and the process holds its session lock, but not yet the file:
    /// up to 30 seconds with every request held (`reply-held.json`). The lock's name
    /// cannot be worked out without Oh My Pi's code, so this waits for the open file.
    @Test func aBreadcrumbTheProcessDoesNotHoldOpenBindsNothing() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "at-prompt", crumb: "after-first-reply")

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "at-prompt"))

        #expect(evidence == .unavailable(.cannotTellSession(.omp)))
    }

    /// The next process on a reused terminal name finds the last one's breadcrumb,
    /// until its own startup overwrites it with `fresh`.
    @Test(arguments: ["after-second-reply", "reused-terminal-next-process"])
    func aBreadcrumbAnEarlierProcessLeftBindsNothing(_ crumb: String) async throws {
        let run = try OMPRun()
        let rig = Rig()
        let previous = try run.agent(in: "at-prompt")
        // The recording's second process, from the same events.
        let next = 9524
        await rig.table.add(
            .init(
                pid: next, parent: previous.parent, name: "omp", start: "200000",
                environment: previous.environment.merging(["HOME": OMPRun.home]) { $1 }, openFiles: [run.tty]))
        await rig.files.write(try run.evidence.breadcrumb(crumb), at: run.crumbPath)

        let evidence = try await rig.binder(.omp).check(
            try PiHostEvidence.terminal(events: OMPRun.events, foregroundPid: next))

        #expect(evidence == .unavailable(.cannotTellSession(.omp)))
    }

    /// A `fresh` breadcrumb is a session not written yet, whatever else is open, as
    /// after the scan's own `SessionManager.create` (ADR 0034).
    @Test func aFreshBreadcrumbBindsNothingEvenOverAnOpenFile() async throws {
        let run = try OMPRun()
        let rig = Rig()
        let fresh = try run.namedFile("reused-terminal-next-process")
        let process = try run.agent(in: "at-prompt")
        await rig.add(
            try run.evidence.scene("at-prompt"), environment: ["HOME": OMPRun.home],
            filesOf: [process.pid: [run.tty, fresh]])
        await rig.files.write(try run.evidence.breadcrumb("reused-terminal-next-process"), at: run.crumbPath)

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "at-prompt"))

        #expect(evidence == .unavailable(.cannotTellSession(.omp)))
    }

    @Test(arguments: [[String](), ["/dev/pts/0", "/dev/pts/3"]])
    func anUnclearTerminalReadsNoBreadcrumb(_ terminals: [String]) async throws {
        let run = try OMPRun()
        let rig = Rig()
        let scene = try run.evidence.scene("after-first-reply")
        let process = try run.agent(in: "after-first-reply")
        await rig.add(scene, environment: ["HOME": OMPRun.home], filesOf: [process.pid: terminals])
        await rig.files.write(try run.evidence.breadcrumb("after-first-reply"), at: run.crumbPath)

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "after-first-reply"))

        #expect(evidence == .unavailable(.cannotTellSession(.omp)))
        #expect(await rig.reads.isEmpty)
    }

    @Test(arguments: ["", "one line", "/cwd\nrelative.jsonl\n", "/cwd\n/a/../b.jsonl\n", "/cwd\n/x.txt\n"])
    func aBreadcrumbThatDoesNotReadBindsNothing(_ text: String) async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "after-first-reply", crumb: nil)
        await rig.files.write(Data(text.utf8), at: run.crumbPath)

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "after-first-reply"))

        #expect(evidence == .unavailable(.cannotTellSession(.omp)))
    }

    /// The breadcrumb the program wrote is the one that counts: another folder's
    /// says nothing of this process, however the core's own environment reads.
    @Test func theBreadcrumbIsReadFromTheAgentsOwnDirectory() async throws {
        let run = try OMPRun()
        let rig = Rig()
        let process = try run.agent(in: "after-first-reply")
        let file = try run.namedFile("after-first-reply")
        await rig.add(
            try run.evidence.scene("after-first-reply"),
            environment: ["HOME": "/home/agent", "PI_CODING_AGENT_DIR": "/srv/omp"],
            filesOf: [process.pid: [run.tty]])
        await rig.files.write(try run.evidence.breadcrumb("after-first-reply"), at: "/srv/omp/terminal-sessions/\(run.terminal)")
        await rig.files.write(try run.evidence.breadcrumb("after-new"), at: "/home/core/.omp/agent/terminal-sessions/\(run.terminal)")

        let evidence = try await rig.binder(.omp).check(try run.record(scene: "after-first-reply"))

        #expect(evidence == .bound(sessionID: file, transcriptRoot: "/srv/omp/sessions", directory: nil))
        #expect(await rig.reads == ["/srv/omp/terminal-sessions/\(run.terminal)"])
    }

    /// After the first reply a broker and a worker that also calls itself `omp` share
    /// the Terminal's scope. The foreground is the Agent, not either of them.
    @Test func ompsOwnHelpersAreNotTheAgent() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "after-new", crumb: "after-new")
        let scene = try run.evidence.scene("after-new")
        #expect(scene.processes.filter { $0.name == "omp" }.count == 2)
        let process = try run.agent(in: "after-new")
        let label = Self.label(session: Self.otherSession, pid: process.pid, start: process.start)

        let evidence = try await rig.binder(.omp).check(
            try run.record(scene: "after-new", labels: ["heeler.session": label]))

        #expect(evidence == .bound(sessionID: Self.otherSession, transcriptRoot: run.sessions, directory: nil))
        #expect(await rig.labels.cleared.isEmpty)
    }

    @Test func aCheckCostsAtMostOneExecAndOneRead() async throws {
        let run = try OMPRun()
        let rig = Rig()
        try await run.set(rig: rig, scene: "after-first-reply", crumb: "after-first-reply")
        let label = Self.label(session: Self.otherSession, pid: 9, start: "1")

        _ = try await rig.binder(.omp).check(
            try run.record(scene: "after-first-reply", labels: ["heeler.session": label]))

        #expect(await rig.table.requests.count == 1)
        #expect(await rig.reads.count == 1)
        #expect(await rig.files.statuses.isEmpty)
        #expect(await rig.files.listings.isEmpty)
    }
}
