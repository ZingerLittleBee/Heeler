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
    /// `/proc/<pid>/fd` targets, which name the same files.
    private nonisolated static func agyRig(_ scene: String) async throws -> (ScriptedProcessTable, HerdrCoreTerminalRecord) {
        let row = try #require(try HostEvidenceFixture.named("agy/presence-lock-1.5.3").scene(scene).processes?.first)
        var process = row.process
        process.environment["HOME"] = home
        process.openFiles = row.files.map { $0.replacingOccurrences(of: "/Users/developer", with: home) }
        let table = ScriptedProcessTable()
        await table.add(process)
        let name = JSONValue.string("agy")
        let record = try JSONDecoder().decode(
            HerdrCoreTerminalRecord.self,
            from: try JSONEncoder().encode(
                JSONValue.object([
                    "address": .string("t1"), "cwd": .string("\(home)/user/projects/agy"), "state": .string("live"),
                    "argv": .array([name]), "keep": .bool(true), "title": .string(""), "cols": .number(80),
                    "rows": .number(24), "name": .null, "reason": .null, "pid": .number(Double(row.pid)),
                    "labels": .object([:]),
                    "foreground": .object([
                        "pid": .number(Double(row.pid)), "name": name, "argv": .array([name]),
                        "cwd": .string("\(home)/user/projects/agy"),
                    ]),
                ])))
        return (table, record)
    }

    /// Each scene and the conversation its lock names, none before the first prompt
    /// and none for a second agy on a conversation already open.
    private nonisolated static let agyScenes: [(scene: String, session: String?)] = [
        ("after-first-prompt", "00000000-0000-4000-8000-000000000103"),
        ("follow-after-fork", "00000000-0000-4000-8000-000000000105"),
        ("at-prompt", nil),
        ("second-instance", nil),
    ]

    @Test(arguments: agyScenes)
    func antigravityBindsFromTheLockItHolds(_ entry: (scene: String, session: String?)) async throws {
        let (scene, session) = entry
        let (table, record) = try await Self.agyRig(scene)
        let files = VirtualHostFiles(home: Self.home)
        let binder = HerdrCoreSessionBinder(
            program: .agy, processes: { try await table.read($0) }, files: files.hostFiles(), clearLabels: { _ in })

        let evidence = try await binder.check(record)

        #expect(
            evidence
                == session.map { .bound(sessionID: $0, transcriptRoot: "\(Self.home)/.gemini/antigravity-cli", directory: nil) }
                ?? Self.cannotTell(.agy))
        #expect(await table.requests.count == 1)
        #expect(await files.reads.isEmpty)
    }
}
