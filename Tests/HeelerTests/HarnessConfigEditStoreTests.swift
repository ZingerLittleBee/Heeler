import Foundation
import Testing

@testable import Heeler

/// The Grok Build offer through the Console: which Agents have it, and the walk from
/// the file read to the user's word and the undo, on a scripted core Host.
@MainActor
@Suite struct HarnessConfigEditStoreTests {
    private static let config = "/home/dev/.grok/config.toml"
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
        #expect(flow.phase == .idle)

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
