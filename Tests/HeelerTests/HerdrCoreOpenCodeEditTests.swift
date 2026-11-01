import Foundation
import SwiftUI
import Testing
import UIKit

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
            openCodePluginBundle: { bundle })
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

    @Test func theUnavailableStateShowsTheOfferAsRendered() async throws {
        let offering = try await labels(
            of: ChatUnavailableView(
                reason: .cannotTellSession(.opencode), retry: {}, showAgentTerminal: {}, reviewEdit: {}),
            showing: "Let Chat Follow OpenCode")
        #expect(offering.contains { $0.contains("Let Chat Follow OpenCode") }, "\(offering)")

        let notOffering = try await labels(
            of: ChatUnavailableView(
                reason: .cannotTellSession(.grok), retry: {}, showAgentTerminal: {}, reviewEdit: {}),
            showing: "Can't Tell the Conversation")
        #expect(!notOffering.contains { $0.contains("Let Chat Follow OpenCode") }, "\(notOffering)")
    }

    @Test func theOfferShowsTheFileTheEntryAndTheFolderWithNothingWritten() async throws {
        let files = InMemoryHostFiles(files: [Self.tuiConfig: Self.original])
        let (store, _, host) = try await started(files: files)
        defer { store.setHosts([]) }
        let flow = flow(store, host)

        await flow.locate()
        #expect(flow.phase == .idle)
        #expect(await files.journal.isEmpty)

        let change = try await reviewed(flow)

        #expect(change.path == Self.tuiConfig)
        #expect(
            change.shownLines == [
                .init(kind: .added, text: #"  "plugin": ["./heeler-opencode"],"#, endsWithoutNewline: false)
            ])
        #expect(change.folder?.path == Self.folder)
        #expect(
            change.folder?.filePaths == [
                "\(Self.folder)/package.json", "\(Self.folder)/index.js", "\(Self.folder)/tui.js",
            ])
        #expect(await files.journal.isEmpty)

        // The same, as the sheet draws it.
        let shown = try await labels(of: OpenCodePluginEditSheet(flow: flow), showing: "Apply")
        #expect(shown.contains { $0.contains(Self.tuiConfig) }, "\(shown)")
        #expect(shown.contains { $0.contains(#""plugin": ["./heeler-opencode"]"#) }, "\(shown)")
        #expect(shown.contains { $0.contains(Self.folder) }, "\(shown)")
        #expect(shown.contains { $0.contains("\(Self.folder)/tui.js") }, "\(shown)")
        #expect(await files.journal.isEmpty)

        flow.cancel()
        #expect(flow.applied == nil)
        #expect(await files.journal.isEmpty)
        #expect(store.harnessEdits.edits(on: host.id).isEmpty)
    }

    /// What a view shows in a real window, once `text` is among it.
    private func labels<Content: View>(of view: Content, showing text: String) async throws -> [String] {
        let controller = UIHostingController(rootView: view)
        var found: [String] = []
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { _ in
            let deadline = ContinuousClock.now + .seconds(5)
            repeat {
                found = AccessibilityProbe.labels(in: controller.view)
                if found.contains(where: { $0.contains(text) }) { return }
                try await Task.sleep(for: .milliseconds(20))
            } while ContinuousClock.now < deadline
        }
        return found
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
    @Test(arguments: ["XDG_CONFIG_HOME", "HOME"])
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

    // MARK: What to do by hand

    /// A list in the wrong file or under the wrong key does nothing and looks as if
    /// it did, so what the sheet says follows the release, as the edit itself does.
    @Test(arguments: [
        (
            "1.19.5", "/home/dev/.config/opencode/tui.json", #"{"plugin": "a"}"#,
            #"Add "./heeler-opencode" to plugin in tui.json, with a copy of Heeler's plugin in a folder of that name beside the file."#
        ),
        (
            "1.19.5", "/home/dev/.config/opencode/tui.jsonc", "not json",
            #"Add "./heeler-opencode" to plugin in tui.jsonc, with a copy of Heeler's plugin in a folder of that name beside the file."#
        ),
        (
            "opencode v2.2.5", "/home/dev/.config/opencode/cli.json", #"{"plugins": "a"}"#,
            #"Add "./heeler-opencode" to plugins in cli.json, with a copy of Heeler's plugin in a folder of that name beside the file."#
        ),
        (
            "opencode v2.0.32", "/home/dev/.config/opencode/cli.json", "not json",
            #"Add "./heeler-opencode" to plugins in cli.json, with a copy of Heeler's plugin in a folder of that name beside the file."#
        ),
    ])
    func aRefusalSaysWhatToAddForThatRelease(
        _ version: String, _ path: String, _ file: String, _ instruction: String
    ) async throws {
        let files = InMemoryHostFiles(files: [path: Data(file.utf8)])
        let (store, _, host) = try await started(version: version, files: files)
        defer { store.setHosts([]) }
        let flow = flow(store, host)

        await flow.review()

        let shown = try await labels(of: OpenCodePluginEditSheet(flow: flow), showing: instruction)
        #expect(shown.contains { $0.contains(path) }, "\(shown)")
        #expect(shown.contains { $0.contains(instruction) }, "\(shown)")
        #expect(await files.journal.isEmpty)
    }

    /// With no release to go on, both forms are what's left to say.
    @Test func aVersionItCantReadSaysWhatToAddOnEachRelease() async throws {
        let (store, _, host) = try await started(version: nil)
        defer { store.setHosts([]) }
        let flow = flow(store, host)
        let instruction =
            #"Add "./heeler-opencode" to plugin in tui.json on OpenCode 1.x, or to plugins in cli.json on 2.x, with a copy of Heeler's plugin in a folder of that name beside the file."#

        await flow.review()

        let shown = try await labels(of: OpenCodePluginEditSheet(flow: flow), showing: instruction)
        #expect(shown.contains { $0.contains(instruction) }, "\(shown)")
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
