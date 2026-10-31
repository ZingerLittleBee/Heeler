import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// The Grok Build offer through the Console: which Agents have it, and the walk from
/// the file read to the user's word and the undo, on a scripted core Host.
@MainActor
@Suite struct HarnessConfigEditStoreTests {
    private static let config = "/home/dev/.grok/config.toml"
    private static let otherHome = "/opt/grok"
    private static let otherConfig = "/opt/grok/config.toml"
    private static let original = Data("[agent]\nname = \"a\"\n".utf8)
    private static let edited = Data(
        "[agent]\nname = \"a\"\n\n[ui.notifications]\nprogram_status = \"on\"\n".utf8)

    private static let unreadableEnvironment =
        "Heeler couldn't read this Agent's environment, so it can't tell which file to change. Nothing was written."

    private static func record(_ address: String, foreground: [String], status: JSONValue = .null, reported: Bool = false) -> JSONValue {
        .object([
            "address": .string(address), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "reported": .bool(reported), "status": status,
            "foreground": .object([
                "pid": .number(70), "name": .string(foreground[0]),
                "argv": .array(foreground.map(JSONValue.string)), "cwd": .string("/work/app"),
            ]),
        ])
    }

    private static func report(_ state: String, app: String) -> JSONValue {
        .object(["state": .string(state), "app": .string(app)])
    }

    private func started(
        _ terminals: [JSONValue], files: InMemoryHostFiles = InMemoryHostFiles()
    ) async throws -> (ConsoleStore, ScriptedCoreTransport, Host) {
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let transport = ScriptedCoreTransport(
            subscribeResults: [
                .object(["seq": .number(1), "terminals": .array(terminals), "channel": .number(1)])
            ],
            services: files)
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) })
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return (store, transport, host)
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func id(_ host: Host, _ pane: String) -> ConsoleAgent.ID {
        ConsoleAgent.ID(hostID: host.id, paneID: pane)
    }

    private func grokFlow(_ store: ConsoleStore, _ host: Host) -> HarnessConfigEditFlow {
        store.grokBuildEditFlow(on: host.id, process: 70)
    }

    // MARK: Which Agents have it

    @Test func onlyAGrokBuildAgentWithUnknownStatusHasTheOffer() async throws {
        let (store, _, host) = try await started([
            Self.record("silent-grok", foreground: ["grok"]),
            Self.record(
                "reporting-grok", foreground: ["grok"], status: Self.report("idle", app: "grok-build"),
                reported: true),
            Self.record("silent-claude", foreground: ["claude"]),
            Self.record(
                "reporting-claude", foreground: ["claude"], status: Self.report("working", app: "claude-code"),
                reported: true),
        ])
        defer { store.setHosts([]) }

        #expect(store.coreStatusExplanations[id(host, "silent-grok")]?.offersGrokBuildEdit == true)
        #expect(store.coreStatusExplanations[id(host, "reporting-grok")] == nil)
        #expect(store.coreStatusExplanations[id(host, "silent-claude")]?.offersGrokBuildEdit == false)
        #expect(store.coreStatusExplanations[id(host, "reporting-claude")] == nil)
    }

    @Test func aShellTerminalHasNoExplanation() async throws {
        let (store, _, host) = try await started([
            Self.record("grok", foreground: ["grok"]),
            Self.record("shell", foreground: ["/bin/zsh"]),
        ])
        defer { store.setHosts([]) }
        #expect(store.coreStatusExplanations[id(host, "shell")] == nil)
    }

    // MARK: The walk

    @Test func nothingIsWrittenBeforeTheUserAccepts() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)
        await flow.locate()
        #expect(flow.phase == .idle)
        #expect(await files.replaceCalls == 0)

        await flow.review()
        guard case .review(let change) = flow.phase else {
            Issue.record("expected a review, got \(flow.phase)")
            return
        }
        #expect(change.path == Self.config)
        #expect(await files.replaceCalls == 0)

        flow.cancel()
        #expect(flow.phase == .idle)
        #expect(flow.applied == nil)
        #expect(await files.replaceCalls == 0)
        #expect(await files.files[Self.config] == Self.original)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
    }

    @Test func acceptingWritesWhatWasShownAndUndoRestoresIt() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)

        await flow.review()
        guard case .review(let change) = flow.phase else {
            Issue.record("expected a review, got \(flow.phase)")
            return
        }
        #expect(
            change.shownLines == [
                .init(kind: .added, text: "", endsWithoutNewline: false),
                .init(kind: .added, text: "[ui.notifications]", endsWithoutNewline: false),
                .init(kind: .added, text: #"program_status = "on""#, endsWithoutNewline: false),
            ])

        await flow.accept()
        #expect(await files.files[Self.config] == Self.edited)
        #expect(flow.phase == .idle)
        let applied = try #require(flow.applied)
        // Host detail reads the same record.
        #expect(store.harnessEdits.edits(on: host.id) == [applied])
        #expect(applied.harness == "Grok Build")
        #expect(applied.path == Self.config)

        await flow.undo()
        #expect(await files.files[Self.config] == Self.original)
        #expect(flow.applied == nil)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
    }

    /// Host detail's own flow, on what the Agent's flow applied: the Agent can
    /// have reported or gone by then.
    @Test func hostDetailUndoesTheAppliedEdit() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)
        await flow.review()
        await flow.accept()

        let edit = try #require(store.harnessEdits.edits(on: host.id).first)
        let hostFlow = store.harnessEditFlow(for: edit, on: host.id)
        await hostFlow.undo()

        #expect(await files.files[Self.config] == Self.original)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
        // The Agent's offer is back.
        #expect(flow.applied == nil)
    }

    @Test func aFileChangedAfterReviewIsRefusedAndTheUserIsTold() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)
        await flow.review()
        let theirs = Data("# theirs\n".utf8)
        await files.set(Self.config, theirs)

        await flow.accept()

        #expect(await files.files[Self.config] == theirs)
        #expect(
            flow.phase
                == .failed("The file changed after Heeler read it, so nothing was written. Review the change again."))
        #expect(flow.applied == nil)
        #expect(!flow.canForget)
    }

    @Test func aFileChangedAfterTheEditRefusesUndoAndCanBeForgotten() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)
        await flow.review()
        await flow.accept()
        let theirs = Self.edited + Data("# mine\n".utf8)
        await files.set(Self.config, theirs)

        await flow.undo()

        #expect(await files.files[Self.config] == theirs)
        #expect(
            flow.phase
                == .failed("The file changed after Heeler edited it, so nothing was written. Undo the edit by hand if you still want to."))
        #expect(flow.applied != nil)
        #expect(flow.canForget)

        flow.forget()
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
        #expect(await files.files[Self.config] == theirs)
    }

    @Test func theFileAlreadySayingSoWritesNothing() async throws {
        let files = InMemoryHostFiles(files: [
            Self.config: Data("[ui.notifications]\nprogram_status = \"on\"\n".utf8)
        ])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)

        await flow.review()
        #expect(flow.phase == .alreadyApplied(path: Self.config))
        #expect(await files.replaceCalls == 0)
    }

    @Test func aFileItWontChangeShowsWhyAndWritesNothing() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Data("ui = { theme = \"dark\" }\n".utf8)])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)

        await flow.review()
        guard case .refused(let path, _) = flow.phase else {
            Issue.record("expected a refusal, got \(flow.phase)")
            return
        }
        #expect(path == Self.config)
        #expect(await files.replaceCalls == 0)
    }

    @Test func aFailedReadSaysSoAndWritesNothing() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        await files.setFailure(TransportError.hostFileTimedOut)
        let flow = grokFlow(store, host)

        await flow.review()
        guard case .failed = flow.phase else {
            Issue.record("expected a failure, got \(flow.phase)")
            return
        }
        #expect(await files.replaceCalls == 0)
    }

    // MARK: Which file

    @Test func theAgentsGrokHomeNamesTheFile() async throws {
        let custom = "/opt/grok/config.toml"
        let files = InMemoryHostFiles(files: [custom: Self.original])
        let (store, transport, host) = try await started(
            [Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        await transport.setProcessVariable("GROK_HOME", to: "/opt/grok")
        let explanation = try #require(store.coreStatusExplanations[id(host, "g")])
        let flow = store.grokBuildEditFlow(on: host.id, process: explanation.agentProcess)

        await flow.review()
        guard case .review(let change) = flow.phase else {
            Issue.record("expected a review, got \(flow.phase)")
            return
        }
        #expect(change.path == custom)
        #expect(await transport.processVariableReads == ["GROK_HOME of 70"])
    }

    @Test func aGrokHomeThatIsNoAbsolutePathIsRefused() async throws {
        let files = InMemoryHostFiles()
        let (store, transport, host) = try await started(
            [Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        await transport.setProcessVariable("GROK_HOME", to: "grok")
        let flow = grokFlow(store, host)

        await flow.review()
        #expect(flow.phase == .failed(HarnessConfigEditError.unresolvedPath.errorDescription ?? ""))
        #expect(await files.replaceCalls == 0)
    }

    /// Unreadable is not unset: that Agent's `GROK_HOME` may name another file, and
    /// an edit to the default one would never reach its program.
    @Test func anEnvironmentThatCannotBeReadIsRefusedRatherThanTakenForUnset() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, transport, host) = try await started(
            [Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        await transport.makeProcessVariableUnavailable("GROK_HOME")
        let flow = grokFlow(store, host)

        await flow.review()

        #expect(flow.phase == .failed(Self.unreadableEnvironment))
        #expect(await transport.processVariableReads == ["GROK_HOME of 70"])
        #expect(await files.replaceCalls == 0)
        #expect(flow.applied == nil)
    }

    @Test func anAgentWithNoProcessToReadIsRefused() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started(
            [Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = store.grokBuildEditFlow(on: host.id, process: nil)

        await flow.review()

        #expect(flow.phase == .failed(Self.unreadableEnvironment))
        #expect(await files.replaceCalls == 0)
    }

    /// The environment read, with no `GROK_HOME` in it, is what the default file is for.
    @Test func anUnsetGrokHomeNamesTheDefaultFile() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, transport, host) = try await started(
            [Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let flow = grokFlow(store, host)

        await flow.review()

        guard case .review(let change) = flow.phase else {
            Issue.record("expected a review, got \(flow.phase)")
            return
        }
        #expect(change.path == Self.config)
        #expect(await transport.processVariableReads == ["GROK_HOME of 70"])
    }

    // MARK: One Host, more than one file

    /// The edit made to the default file, then to the file `GROK_HOME` names: two
    /// Agents on one Host that read different files.
    private func appliedToBothFiles() async throws -> (
        ConsoleStore, InMemoryHostFiles, Host, first: HarnessConfigEditFlow, second: HarnessConfigEditFlow
    ) {
        let files = InMemoryHostFiles(files: [Self.config: Self.original, Self.otherConfig: Self.original])
        let (store, transport, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        let first = grokFlow(store, host)
        await first.review()
        await first.accept()
        await transport.setProcessVariable("GROK_HOME", to: Self.otherHome)
        let second = grokFlow(store, host)
        await second.review()
        await second.accept()
        return (store, files, host, first, second)
    }

    private func row(
        _ store: ConsoleStore, _ host: Host, path: String
    ) throws -> HarnessConfigEditFlow {
        let edit = try #require(store.harnessEdits.edits(on: host.id).first { $0.path == path })
        return store.harnessEditFlow(for: edit, on: host.id)
    }

    /// An edit of another file says nothing about the one this Agent reads.
    @Test func anAgentReadingAnotherFileIsStillOfferedItsOwn() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original, Self.otherConfig: Self.original])
        let (store, transport, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let first = grokFlow(store, host)
        await first.review()
        await first.accept()
        await transport.setProcessVariable("GROK_HOME", to: Self.otherHome)

        let second = grokFlow(store, host)
        await second.locate()

        #expect(second.phase == .idle)
        #expect(second.applied == nil)

        await second.review()
        guard case .review(let change) = second.phase else {
            Issue.record("expected a review, got \(second.phase)")
            return
        }
        #expect(change.path == Self.otherConfig)

        await second.accept()
        #expect(await files.files[Self.otherConfig] == Self.edited)
        #expect(await files.files[Self.config] == Self.edited)
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.config, Self.otherConfig])
        #expect(first.applied?.path == Self.config)
        #expect(second.applied?.path == Self.otherConfig)
    }

    @Test func anAgentFindsTheEditOfItsOwnFileWhenItsSheetOpens() async throws {
        let (store, files, host, _, _) = try await appliedToBothFiles()
        defer { store.setHosts([]) }
        let flow = store.grokBuildEditFlow(on: host.id, process: 70)

        // No claim before the file is known.
        #expect(flow.phase == .locating)
        #expect(flow.applied == nil)

        await flow.locate()

        #expect(flow.phase == .idle)
        #expect(flow.applied?.path == Self.otherConfig)
        #expect(await files.replaceCalls == 2)
    }

    @Test func undoInOneAgentsSheetLeavesTheOtherFile() async throws {
        let (store, files, host, first, second) = try await appliedToBothFiles()
        defer { store.setHosts([]) }

        await first.undo()

        #expect(await files.files[Self.config] == Self.original)
        #expect(await files.files[Self.otherConfig] == Self.edited)
        #expect(first.applied == nil)
        #expect(second.applied?.path == Self.otherConfig)
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.otherConfig])
    }

    /// A row shows its own file, whichever edit is newest.
    @Test func hostDetailUndoesTheFileItsRowShows() async throws {
        let (store, files, host, _, _) = try await appliedToBothFiles()
        defer { store.setHosts([]) }

        try await row(store, host, path: Self.config).undo()

        #expect(await files.files[Self.config] == Self.original)
        #expect(await files.files[Self.otherConfig] == Self.edited)
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.otherConfig])

        try await row(store, host, path: Self.otherConfig).undo()

        #expect(await files.files[Self.otherConfig] == Self.original)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
    }

    @Test func aRowRefusedOnItsOwnFileStopsListingOnlyItself() async throws {
        let (store, files, host, _, _) = try await appliedToBothFiles()
        defer { store.setHosts([]) }
        let theirs = Self.edited + Data("# mine\n".utf8)
        await files.set(Self.config, theirs)
        let flow = try row(store, host, path: Self.config)

        await flow.undo()

        #expect(flow.canForget)
        #expect(await files.files[Self.config] == theirs)
        #expect(await files.files[Self.otherConfig] == Self.edited)

        flow.forget()

        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.otherConfig])
        #expect(await files.files[Self.config] == theirs)
    }

    /// Which file is not known, so no edit is this Agent's. Host detail still lists it.
    @Test func anAgentWhoseFileCannotBeFoundClaimsNoEdit() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, transport, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let first = grokFlow(store, host)
        await first.review()
        await first.accept()
        await transport.makeProcessVariableUnavailable("GROK_HOME")

        let flow = grokFlow(store, host)
        await flow.locate()

        #expect(flow.phase == .idle)
        #expect(flow.applied == nil)
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.config])

        await flow.review()
        #expect(flow.phase == .failed(Self.unreadableEnvironment))
        #expect(await files.replaceCalls == 1)
    }

    /// The read that failed when the sheet opened now works, and this file already
    /// holds Heeler's edit: what is left to offer is its Undo.
    @Test func aReviewOfAFileWithThisEditShowsItsUndo() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, transport, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let first = grokFlow(store, host)
        await first.review()
        await first.accept()
        await transport.makeProcessVariableUnavailable("GROK_HOME")
        let flow = grokFlow(store, host)
        await flow.locate()
        await transport.setProcessVariable("GROK_HOME", to: "/home/dev/.grok")

        await flow.review()

        #expect(flow.phase == .idle)
        #expect(flow.applied?.path == Self.config)
        #expect(await files.replaceCalls == 1)

        await flow.undo()
        #expect(await files.files[Self.config] == Self.original)
    }

    // MARK: The sheet

    /// The sheet's labels once it shows `expected`, or as they stand when time runs out.
    private func sheetLabels(
        _ store: ConsoleStore, _ host: Host, showing expected: String
    ) async throws -> [String] {
        let explanation = try #require(store.coreStatusExplanations[id(host, "g")])
        let controller = UIHostingController(
            rootView: HerdrCoreStatusExplanationSheet(console: store, hostID: host.id, explanation: explanation))
        var labels: [String] = []
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                labels = AccessibilityProbe.labels(in: controller.view)
                if labels.contains(where: { $0.contains(expected) }) { return }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
        }
        return labels
    }

    @Test func theSheetOffersAnAgentReadingAnotherFile() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original, Self.otherConfig: Self.original])
        let (store, transport, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let first = grokFlow(store, host)
        await first.review()
        await first.accept()
        await transport.setProcessVariable("GROK_HOME", to: Self.otherHome)

        let labels = try await sheetLabels(store, host, showing: "Turn On Grok Build's Status")

        #expect(labels.contains { $0.contains("Turn On Grok Build's Status") }, "\(labels)")
        #expect(!labels.contains { $0.contains("Undo") }, "\(labels)")
        #expect(!labels.contains { $0.contains(Self.config) }, "\(labels)")
        #expect(await files.replaceCalls == 1)
    }

    @Test func theSheetShowsTheEditOfItsAgentsOwnFile() async throws {
        let files = InMemoryHostFiles(files: [Self.config: Self.original])
        let (store, _, host) = try await started([Self.record("g", foreground: ["grok"])], files: files)
        defer { store.setHosts([]) }
        let first = grokFlow(store, host)
        await first.review()
        await first.accept()

        let labels = try await sheetLabels(store, host, showing: "Undo")

        #expect(labels.contains { $0.contains("Undo") }, "\(labels)")
        #expect(labels.contains { $0.contains(Self.config) }, "\(labels)")
        #expect(!labels.contains { $0.contains("Turn On Grok Build's Status") }, "\(labels)")
    }

    // MARK: Staying with the Host

    @Test func appliedEditsAreRememberedAndGoWithTheHost() throws {
        let suite = "HarnessConfigEditStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hostID = Host.ID()
        let edit = HarnessConfigAppliedEdit(
            id: UUID(), editID: GrokBuildProgramStatusEdit.id, harness: "Grok Build", path: Self.config,
            hunk: HarnessConfigHunk(before: Self.original, after: Self.edited), createdFile: false,
            writtenDigest: Data([1]), appliedAt: Date(timeIntervalSince1970: 0))

        HarnessConfigEditStore(defaults: defaults).note(edit, on: hostID)
        let reopened = HarnessConfigEditStore(defaults: defaults)
        #expect(reopened.edits(on: hostID) == [edit])

        reopened.retainHosts([])
        #expect(HarnessConfigEditStore(defaults: defaults).edits(on: hostID).isEmpty)
    }

    @Test func reapplyingToAFileReplacesWhatWasKnownOfIt() {
        let store = HarnessConfigEditStore()
        let hostID = Host.ID()
        func edit(_ path: String) -> HarnessConfigAppliedEdit {
            HarnessConfigAppliedEdit(
                id: UUID(), editID: GrokBuildProgramStatusEdit.id, harness: "Grok Build", path: path,
                hunk: HarnessConfigHunk(before: Self.original, after: Self.edited), createdFile: false,
                writtenDigest: Data([1]), appliedAt: Date(timeIntervalSince1970: 0))
        }
        let first = edit("/a")
        let second = edit("/a")
        let other = edit("/b")
        store.note(first, on: hostID)
        store.note(other, on: hostID)
        store.note(second, on: hostID)
        #expect(store.edits(on: hostID) == [other, second])
    }
}
