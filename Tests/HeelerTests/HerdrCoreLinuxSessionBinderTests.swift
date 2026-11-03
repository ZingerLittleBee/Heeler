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
            "pi-launch", .pi,
            .bound(
                sessionID: "00000000-0000-4000-8000-000000000005", transcriptRoot: "\(home)/.pi/agent/sessions",
                directory: nil)
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

    @Test(arguments: recorded)
    func aCheckCostsOneExecAndOneReadAndNamesItsVariables(
        _ entry: (scene: String, program: ChatProgram, evidence: ChatSessionEvidence)
    ) async throws {
        let rig = try await Rig(entry.scene)

        _ = try await rig.binder(entry.program).check(try rig.record())

        let requests = await rig.table.requests
        #expect(requests.count == 1)
        #expect(await rig.files.reads.count <= 1)
        #expect(await rig.files.listings.isEmpty)
        let request = try #require(requests.first)
        let asked = request.valuesOf + request.namesOf
        #expect(!asked.contains { $0.hasPrefix("HERDR_") })
        #expect(request.namesWithPrefix.isEmpty)
        #expect(asked.contains("HC_SCOPE"))
    }
}
