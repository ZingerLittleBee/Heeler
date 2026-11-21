import Foundation
import Testing

@testable import Heeler

/// The OpenCode edit through the Console, on a scripted core Host: which file its
/// flow names, that nothing is written before the user's word, and what a detail
/// that has left its core may still do.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HerdrCoreOpenCodeEditTests {
    private static let directory = "/home/dev/.config/opencode"
    private static let folder = "/home/dev/.config/opencode/heeler-opencode"
    private static let tuiConfig = "/home/dev/.config/opencode/tui.json"
    private static let tuiConfigC = "/home/dev/.config/opencode/tui.jsonc"
    private static let cliConfig = "/home/dev/.config/opencode/cli.json"
    private static let original = Data("{\n  \"theme\": \"dark\"\n}\n".utf8)

    private static let bundle = HostHelperFixture.bundle(
        extraFiles: Dictionary(
            uniqueKeysWithValues: OpenCodePluginEdit.fileNames.map {
                ("extensions/opencode/\($0)", Data("// \($0)\n".utf8))
            }))

    private static func record() -> JSONValue {
        .object([
            "address": .string("oc"), "cwd": .string("/work/app"), "state": .string("live"),
            "argv": .array([.string("/bin/zsh")]), "cols": .number(80), "rows": .number(24), "pid": .number(7),
            "reported": .bool(false), "status": .null,
            "foreground": .object([
                "pid": .number(70), "name": .string("opencode"),
                "argv": .array([.string("opencode")]), "cwd": .string("/work/app"),
            ]),
        ])
    }

    private func started(
        version: String? = "1.19.5", files: InMemoryHostFiles = InMemoryHostFiles()
    ) async throws -> (ConsoleStore, ScriptedCoreTransport, Host) {
        let host = Host(address: "box.example", username: "dev", serverKind: .herdrCore)
        let transport = ScriptedCoreTransport(
            coreID: "c1",
            subscribeResults: [
                .object(["seq": .number(1), "terminals": .array([Self.record()]), "channel": .number(1)]),
                .object(["seq": .number(1), "terminals": .array([Self.record()]), "channel": .number(1)]),
            ],
            services: files)
        await transport.setDiscovery(programs: ["opencode"], openCodeVersion: version)
        await transport.setShell("/bin/zsh")
        await transport.setProcessVariable("HOME", to: "/home/dev")
        let bundle = Self.bundle
        let store = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeCoreSession: { _ in HerdrCoreHostSession(connect: { transport }, keepalive: nil) },
            harnessEdits: HarnessConfigEditStore(),
            hostHelperBundle: { bundle })
        store.setHosts([host])
        await store.resume()
        try await waitUntil("the first snapshot") { !store.hostsAwaitingSnapshot.contains(host.id) }
        return (store, transport, host)
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func flow(_ store: ConsoleStore, _ host: Host, keepingTo pin: TerminalCorePin? = nil) -> HarnessConfigEditFlow {
        store.openCodePluginEditFlow(for: ConsoleAgent.ID(hostID: host.id, paneID: "oc"), keepingTo: pin)
    }

    private func reviewed(
        _ flow: HarnessConfigEditFlow, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> HarnessConfigPendingChange {
        await flow.review()
        guard case .review(let change) = flow.phase else {
            Issue.record("expected a review, got \(flow.phase)", sourceLocation: sourceLocation)
            throw HarnessConfigEditError.unreadable
        }
        return change
    }

    // MARK: The offer

    @Test func theReasonChatGivesIsWhatOffersTheEdit() {
        #expect(ChatUnavailableReason.cannotTellSession(.opencode).offersOpenCodePluginEdit)
        #expect(!ChatUnavailableReason.cannotTellSession(.grok).offersOpenCodePluginEdit)
        #expect(!ChatUnavailableReason.cannotTellSession(.pi).offersOpenCodePluginEdit)
        #expect(!ChatUnavailableReason.noSession(.opencode).offersOpenCodePluginEdit)
        #expect(!ChatUnavailableReason.startScreen(.opencode).offersOpenCodePluginEdit)
    }

    // MARK: Accepting and undoing

    @Test func acceptingWritesAndUndoPutsItAllBack() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let flow = flow(store, host)
        _ = try await reviewed(flow)

        await flow.accept()

        #expect(flow.phase == .idle)
        let applied = try #require(flow.applied)
        #expect(store.harnessEdits.edits(on: host.id) == [applied])
        #expect(applied.harness == "OpenCode")
        #expect(await files.folders.contains(Self.folder))
        #expect(await files.files["\(Self.folder)/tui.js"] == Data("// tui.js\n".utf8))
        #expect(
            await files.files[Self.tuiConfig]
                == Data("{\n  \"plugin\": [\"./heeler-opencode\"],\n  \"theme\": \"dark\"\n}\n".utf8))

        await flow.undo()

        #expect(flow.applied == nil)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
        #expect(await files.files == [Self.tuiConfig: Self.original])
        #expect(await files.folders.isEmpty)
    }

    @Test func aFileChangedSinceTheReviewIsRefused() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let flow = flow(store, host)
        _ = try await reviewed(flow)
        let changed = Data("{ \"theme\": \"light\" }\n".utf8)
        await files.set(Self.tuiConfig, changed)
        await files.clearJournal()

        await flow.accept()

        #expect(flow.phase == .failed(HarnessConfigEditError.changedSinceRead.errorDescription ?? ""))
        #expect(flow.applied == nil)
        #expect(await files.files[Self.tuiConfig] == changed)
        #expect(await files.journal.isEmpty)
    }

    // MARK: Which file

    @Test(arguments: [
        ("1.19.5", "/home/dev/.config/opencode/tui.json"),
        ("opencode v2.0.32", "/home/dev/.config/opencode/cli.json"),
        ("opencode v2.2.5", "/home/dev/.config/opencode/cli.json"),
    ])
    func theFileFollowsTheProbedVersion(_ version: String, _ path: String) async throws {
        let (store, _, host) = try await started(version: version)
        defer { store.setHosts([]) }

        let change = try await reviewed(flow(store, host))

        #expect(change.path == path)
        #expect(change.createsFile)
    }

    /// hc-lab, 2026-11-03: the login shell found OpenCode 2.2.2, and a 1.19.5 the
    /// Agent's own PATH found was offered the 2.x `cli.json`, which 1.19.5 ignores.
    @Test func theFileFollowsTheAgentsOwnReleaseNotTheLoginShells() async throws {
        let (store, transport, host) = try await started(version: "2.2.2")
        defer { store.setHosts([]) }
        let agentPath = "/home/dev/bin-oc119:/usr/local/bin:/usr/bin:/bin"
        await transport.setProcessVariable("PATH", to: agentPath)
        await transport.setOpenCodeVersion("1.19.5", searching: agentPath)

        let change = try await reviewed(flow(store, host))

        #expect(change.path == Self.tuiConfig)
        let script = try #require(await transport.discoveryScripts.last)
        #expect(script.contains("PATH='\(agentPath)'; export PATH"))
        #expect(script.contains("cd '/work/app'"))
        #expect(script.contains("'opencode' --version"))
        #expect(!script.contains(" -ic "))
        #expect(await transport.processVariableReads.contains("PATH of 70"))
    }

    /// An upgrade while the Console stays connected: under the old release's key the
    /// entry would do nothing, and look as if it did.
    @Test func anUpgradeSinceTheLastLookMovesTheFile() async throws {
        let (store, transport, host) = try await started(version: "1.19.5")
        defer { store.setHosts([]) }
        #expect(try await reviewed(flow(store, host)).path == Self.tuiConfig)

        await transport.setDiscovery(programs: ["opencode"], openCodeVersion: "opencode v2.2.5")

        #expect(try await reviewed(flow(store, host)).path == Self.cliConfig)
    }

    @Test func aJsoncFileThatExistsIsTheOneEdited() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfigC: Data("{ // mine\n}\n".utf8)])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }

        #expect(try await reviewed(flow(store, host)).path == Self.tuiConfigC)
    }

    @Test func aPlainFileWinsOverAJsoncOne() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original, Self.tuiConfigC: Data("{}".utf8)])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }

        #expect(try await reviewed(flow(store, host)).path == Self.tuiConfig)
    }

    @Test func theAgentsOwnConfigHomeNamesTheFile() async throws {
        let (store, transport, host) = try await started(version: "2.2.5")
        defer { store.setHosts([]) }
        await transport.setProcessVariable("XDG_CONFIG_HOME", to: "/srv/cfg")

        let change = try await reviewed(flow(store, host))

        #expect(change.path == "/srv/cfg/opencode/cli.json")
        #expect(change.folder?.path == "/srv/cfg/opencode/heeler-opencode")
        #expect(await transport.processVariableReads.contains("XDG_CONFIG_HOME of 70"))
    }

    @Test func aRelativeConfigHomeNamesNoFile() async throws {
        let (store, transport, host) = try await started()
        defer { store.setHosts([]) }
        await transport.setProcessVariable("XDG_CONFIG_HOME", to: "cfg")
        let flow = flow(store, host)

        await flow.review()

        #expect(flow.phase == .failed(HarnessConfigEditError.unresolvedPath.errorDescription ?? ""))
    }

    /// Unreadable is not unset: taking it for unset would edit a file this Agent may not read.
    @Test(arguments: ["XDG_CONFIG_HOME", "HOME", "PATH"])
    func anEnvironmentItCantReadWritesNothing(_ variable: String) async throws {
        let files = InMemoryHostFiles()
        let (store, transport, host) = try await started(files: files)
        defer { store.setHosts([]) }
        await transport.makeProcessVariableUnavailable(variable)
        let flow = flow(store, host)

        await flow.review()

        #expect(flow.phase == .failed(HarnessConfigEditError.agentEnvironmentUnavailable.errorDescription ?? ""))
        #expect(await files.journal.isEmpty)
    }

    @Test(arguments: [nil, "not a version", "3.0.0"] as [String?])
    func aVersionNobodyHasLookedAtWritesNothing(_ version: String?) async throws {
        let files = InMemoryHostFiles()
        let (store, _, host) = try await started(version: version, files: files)
        defer { store.setHosts([]) }
        let flow = flow(store, host)

        await flow.review()

        #expect(flow.phase == .failed(HarnessConfigEditError.openCodeVersionUnknown.errorDescription ?? ""))
        #expect(await files.journal.isEmpty)
    }

    // MARK: What it promises on each release

    /// Chat doesn't know the release here, and shows a conversation of either.
    @Test func theUnavailableTextNamesThePluginForEveryRelease() {
        let text = ChatUnavailableReason.cannotTellSession(.opencode).explanation
        #expect(text.contains("Heeler's plugin"), "\(text)")
        #expect(!text.contains("2.x"), "\(text)")
    }

    // MARK: Two files, one folder

    private static let edited = Data("{\n  \"plugin\": [\"./heeler-opencode\"],\n  \"theme\": \"dark\"\n}\n".utf8)

    /// The same edit of `tui.jsonc`, and of `tui.json` once that exists: two records
    /// of the one folder.
    private func appliedToBothFiles() async throws -> (ConsoleStore, InMemoryHostFiles, Host) {
        let files = InMemoryHostFiles(files: [Self.tuiConfigC: Self.original])
        let (store, _, host) = try await started(files: files)
        let first = flow(store, host)
        _ = try await reviewed(first)
        await first.accept()
        await files.set(Self.tuiConfig, Self.original)
        let second = flow(store, host)
        _ = try await reviewed(second)
        await second.accept()
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.tuiConfigC, Self.tuiConfig])
        return (store, files, host)
    }

    private func listed(
        _ store: ConsoleStore, _ host: Host, path: String
    ) throws -> HarnessConfigEditFlow {
        store.harnessEditFlow(
            for: try #require(store.harnessEdits.edit(OpenCodePluginEdit.id, path: path, on: host.id)), on: host.id)
    }

    /// A file that still names the folder keeps it, whichever goes first.
    @Test(arguments: [
        ("/home/dev/.config/opencode/tui.jsonc", "/home/dev/.config/opencode/tui.json"),
        ("/home/dev/.config/opencode/tui.json", "/home/dev/.config/opencode/tui.jsonc"),
    ])
    func undoingOneOfTwoFilesKeepsTheFolderForTheOther(_ first: String, _ second: String) async throws {
        let (store, files, host) = try await appliedToBothFiles()
        defer { store.setHosts([]) }

        try await listed(store, host, path: first).undo()

        #expect(await files.files[first] == Self.original)
        #expect(await files.files[second] == Self.edited)
        #expect(await files.folders.contains(Self.folder))
        #expect(await files.files["\(Self.folder)/tui.js"] == Data("// tui.js\n".utf8))
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [second])

        try await listed(store, host, path: second).undo()

        #expect(await files.files == [first: Self.original, second: Self.original])
        #expect(await files.folders.isEmpty)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
    }

    @Test func removingTheHelperUndoesBothFilesAndThenTheFolder() async throws {
        let (store, files, host) = try await appliedToBothFiles()
        defer { store.setHosts([]) }

        let left = try await store.harnessEdits.undoEditsGoingWithTheHelper(on: host.id, over: files)

        #expect(left == nil)
        #expect(await files.files == [Self.tuiConfig: Self.original, Self.tuiConfigC: Self.original])
        #expect(await files.folders.isEmpty)
    }

    /// The file that refused still names the folder, and stays listed with its Undo.
    @Test func aFileThatRefusesKeepsTheFolderThroughTheHelpersRemoval() async throws {
        let (store, files, host) = try await appliedToBothFiles()
        defer { store.setHosts([]) }
        let broken = Data("broken {".utf8)
        await files.set(Self.tuiConfigC, broken)

        let left = try await store.harnessEdits.undoEditsGoingWithTheHelper(on: host.id, over: files)

        #expect(left?.contains(Self.tuiConfigC) == true)
        #expect(await files.files[Self.tuiConfigC] == broken)
        #expect(await files.files[Self.tuiConfig] == Self.original)
        #expect(await files.folders.contains(Self.folder))
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.tuiConfigC])
    }

    /// Taking a folder back is only for one nothing else names.
    @Test func aSecondFileThatChangedTakesNothingFromTheFirst() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfigC: Self.original])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let first = flow(store, host)
        _ = try await reviewed(first)
        await first.accept()
        await files.set(Self.tuiConfig, Self.original)
        let second = flow(store, host)
        _ = try await reviewed(second)
        let changed = Data("{ \"theme\": \"light\" }\n".utf8)
        await files.onReplace(of: Self.tuiConfig) { await $0.set(Self.tuiConfig, changed) }

        await second.accept()

        #expect(second.phase == .failed(HarnessConfigEditError.changedSinceRead.errorDescription ?? ""))
        #expect(await files.files[Self.tuiConfigC] == Self.edited)
        #expect(await files.folders.contains(Self.folder))
        #expect(await files.files["\(Self.folder)/tui.js"] == Data("// tui.js\n".utf8))
    }

    // MARK: A running OpenCode 2.x

    /// What OpenCode 2.2.2 did while it ran on hc-lab (2026-11-03): finding no
    /// `cli.json`, it made one out of `tui.json`, whose `plugin` list became
    /// `plugins` ("migrated cli config", role=cli).
    private nonisolated static func openCode2Running(_ files: InMemoryHostFiles) async {
        guard await files.files[cliConfig] == nil, let tui = await files.files[tuiConfig],
            let object = try? JSONSerialization.jsonObject(with: tui) as? [String: Any]
        else { return }
        var cli: [String: Any] = ["$schema": "https://opencode.ai/v2/cli.json"]
        cli["plugins"] = object["plugin"]
        guard
            let migrated = try? JSONSerialization.data(
                withJSONObject: cli, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        await files.set(cliConfig, migrated)
    }

    /// The 2.x edit, then the 1.x one once the Agent is 1.19.5, each in a file of
    /// its own that Heeler created, as on hc-lab.
    private func appliedForBothReleases() async throws -> (ConsoleStore, InMemoryHostFiles, Host) {
        let files = InMemoryHostFiles()
        let (store, transport, host) = try await started(version: "2.2.2", files: files)
        let newer = flow(store, host)
        _ = try await reviewed(newer)
        await newer.accept()
        await transport.setDiscovery(programs: ["opencode"], openCodeVersion: "1.19.5")
        let older = flow(store, host)
        _ = try await reviewed(older)
        await older.accept()
        #expect(store.harnessEdits.edits(on: host.id).map(\.path) == [Self.cliConfig, Self.tuiConfig])
        return (store, files, host)
    }

    private static func namesTheFolder(_ file: Data?) -> Bool {
        guard let file else { return false }
        return [ConfigForm.tuiConfig, ConfigForm.cliConfig].contains {
            HarnessConfigJSONCList.removing(
                HarnessConfigListEntry(key: $0.listKey, value: OpenCodePluginEdit.entryValue), from: file) != .notThere
        }
    }

    private typealias ConfigForm = OpenCodePluginEdit.ConfigForm

    @Test func removingTheHelperUnderARunningOpenCode2LeavesNoFileNamingTheFolder() async throws {
        let (store, files, host) = try await appliedForBothReleases()
        defer { store.setHosts([]) }
        await files.whileRunning { await Self.openCode2Running($0) }

        let left = try await store.harnessEdits.undoEditsGoingWithTheHelper(on: host.id, over: files)

        #expect(left == nil)
        #expect(await files.files.isEmpty)
        #expect(await files.folders.isEmpty)
    }

    /// Undoing `cli.json` alone lets OpenCode make a new one naming the folder,
    /// which the folder's last undo then takes the entry out of.
    @Test func undoingEachEditUnderARunningOpenCode2LeavesNoFileNamingTheFolder() async throws {
        let (store, files, host) = try await appliedForBothReleases()
        defer { store.setHosts([]) }
        await files.whileRunning { await Self.openCode2Running($0) }

        try await listed(store, host, path: Self.cliConfig).undo()
        #expect(Self.namesTheFolder(await files.files[Self.cliConfig]))
        #expect(await files.folders.contains(Self.folder))

        let last = try listed(store, host, path: Self.tuiConfig)
        await last.undo()

        #expect(last.applied == nil)
        #expect(await files.files.keys.sorted() == [Self.cliConfig])
        #expect(!Self.namesTheFolder(await files.files[Self.cliConfig]))
        #expect(await files.folders.isEmpty)
    }

    // MARK: A folder file that changes under an undo

    /// The entry has gone by then, so "nothing was written" would be false, and
    /// undoing again is what finishes it.
    @Test func aFolderFileChangedDuringUndoSaysSoAndUndoingAgainFinishes() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let flow = flow(store, host)
        _ = try await reviewed(flow)
        await flow.accept()
        let plugin = "\(Self.folder)/index.js"
        await files.onReplace(of: plugin) { await $0.set(plugin, Data("changed".utf8)) }

        await flow.undo()

        #expect(
            flow.phase == .failed(
                "Heeler took its change out of the file, but a file changed while Heeler was removing its folder, so the folder stays. Undo again to finish."))
        #expect(!flow.canForget)
        #expect(await files.files[Self.tuiConfig] == Self.original)
        #expect(flow.applied != nil)

        flow.cancel()
        await flow.undo()

        #expect(flow.applied == nil)
        #expect(await files.files == [Self.tuiConfig: Self.original])
        #expect(await files.folders.isEmpty)
    }

    /// ADR 0033: a refusing file doesn't keep the Helper, and this one is told as words.
    @Test func aFolderFileChangedDuringTheHelpersRemovalDoesNotStopIt() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let flow = flow(store, host)
        _ = try await reviewed(flow)
        await flow.accept()
        let plugin = "\(Self.folder)/index.js"
        await files.onReplace(of: plugin) { await $0.set(plugin, Data("changed".utf8)) }

        let left = try await store.harnessEdits.undoEditsGoingWithTheHelper(on: host.id, over: files)

        #expect(
            left
                == "The Host Helper is gone. Heeler took its change out of the file, but a file changed while Heeler was removing its folder, so the folder stays. Undo again to finish.")
        #expect(store.harnessEdits.edits(on: host.id).count == 1)
    }

    // MARK: A detail keeps to its own core

    /// ADR 0031: past its core, a detail's Agent isn't there to do this for.
    @Test func aDetailThatHasLeftItsCoreWritesNothing() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original])
        let (store, transport, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let pin = store.corePin(on: host.id)
        let reviewing = flow(store, host, keepingTo: pin)
        _ = try await reviewed(reviewing)

        await transport.setCoreID("c2")
        await transport.endLink()
        try await waitUntil("the other core") { store.hasLeftCore(pin, on: host.id) }

        await reviewing.accept()

        guard case .failed = reviewing.phase else {
            Issue.record("expected a refusal, got \(reviewing.phase)")
            return
        }
        #expect(await files.journal.isEmpty)
        #expect(reviewing.applied == nil)

        let late = flow(store, host, keepingTo: pin)
        await late.review()
        guard case .failed = late.phase else {
            Issue.record("expected a refusal, got \(late.phase)")
            return
        }
    }

    /// Host detail keeps to no core: the file is the Host's, and stays undoable.
    @Test func hostDetailStillUndoesAfterTheCoreIsGone() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original])
        let (store, transport, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let pin = store.corePin(on: host.id)
        let offer = flow(store, host, keepingTo: pin)
        _ = try await reviewed(offer)
        await offer.accept()
        let applied = try #require(offer.applied)

        await transport.setCoreID("c2")
        await transport.endLink()
        try await waitUntil("the other core") { store.hasLeftCore(pin, on: host.id) }

        let listed = store.harnessEditFlow(for: applied, on: host.id)
        await listed.undo()

        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
        #expect(await files.files == [Self.tuiConfig: Self.original])
    }
}
