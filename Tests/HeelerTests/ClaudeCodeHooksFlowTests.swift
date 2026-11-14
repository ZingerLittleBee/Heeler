import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

/// Host detail's Claude Code hooks on a tmux Host (ADR 0046): the default root
/// and each Account's, each change shown before it is written, and an undo any
/// device can make.
@MainActor
@Suite struct ClaudeCodeHooksFlowTests {
    private static let locations = HostHelperProbe.Locations(
        home: "/home/dev", dataHome: "/home/dev/.local/share", configHome: "/home/dev/.config")
    private static let script = "/home/dev/.local/share/heeler/claude-code/hook.sh"
    private static let defaultSettings = "/home/dev/.claude/settings.json"
    private static let work = "/home/dev/.claude-work"
    private static let accountFile = "/home/dev/.local/share/heeler/host-helper/usage-accounts.json"

    @MainActor private final class Placements {
        var count = 0
    }

    private func flow(_ files: InMemoryHostFiles, placements: Placements = Placements()) -> ClaudeCodeHooksFlow {
        ClaudeCodeHooksFlow(
            services: { files },
            locate: { Self.locations },
            place: { placements.count += 1 })
    }

    private func accounts() throws -> Data {
        var file = UsageAccountFile()
        try file.add(directory: Self.work, name: "Work", defaultDirectory: nil)
        try file.add(directory: "/home/dev/.claude", name: "Same as default", defaultDirectory: nil)
        return try file.encoded()
    }

    private func root(_ flow: ClaudeCodeHooksFlow, _ path: String) throws -> ClaudeCodeHooksFlow.Root {
        try #require(flow.roots.first { $0.path == path })
    }

    @Test func itListsTheDefaultRootAndEachAccountsWithWhatTheirSettingsRun() async throws {
        let files = InMemoryHostFiles(files: [
            Self.accountFile: try accounts(),
            Self.defaultSettings: ClaudeCodeHooks.launchSettings(script: Self.script),
        ])
        let flow = flow(files)

        await flow.load()

        #expect(flow.phase == .loaded)
        #expect(flow.accountsUnreadable == false)
        #expect(flow.roots == [.init(accountName: nil, path: "/home/dev/.claude"), .init(accountName: "Work", path: Self.work)])
        #expect(flow.states["/home/dev/.claude"] == .read(.on))
        #expect(flow.states[Self.work] == .read(.off))
        #expect(await files.replaceCalls == 0)
    }

    @Test func withNoAccountFileOnlyTheDefaultRootShows() async {
        let flow = flow(InMemoryHostFiles())
        await flow.load()
        #expect(flow.roots.map(\.path) == ["/home/dev/.claude"])
        #expect(flow.states["/home/dev/.claude"] == .read(.off))
    }

    @Test func addingShowsTheChangeThenPlacesTheScriptAndWritesIt() async throws {
        let before = Data("{\n  \"model\": \"opus\"\n}\n".utf8)
        let files = InMemoryHostFiles(files: [Self.accountFile: try accounts(), "\(Self.work)/settings.json": before])
        let placements = Placements()
        let flow = flow(files, placements: placements)
        await flow.load()
        let work = try root(flow, Self.work)

        await flow.review(work, adding: true)

        guard case .review(let change, adding: true) = flow.states[work.id] else {
            Issue.record("expected a review, got \(String(describing: flow.states[work.id]))")
            return
        }
        #expect(change.path == "\(Self.work)/settings.json")
        #expect(change.before == before)
        #expect(placements.count == 0)
        #expect(await files.replaceCalls == 0)

        await flow.accept(work)

        #expect(placements.count == 1)
        #expect(await files.files["\(Self.work)/settings.json"] == change.after)
        #expect(flow.states[work.id] == .read(.on))
        // The default root was not touched.
        #expect(await files.files[Self.defaultSettings] == nil)
    }

    @Test func anotherDeviceRemovesTheHooksAndKeepsTheRest() async throws {
        let before = Data("{\n  \"model\": \"opus\"\n}\n".utf8)
        let files = InMemoryHostFiles(files: [Self.defaultSettings: before])
        let adding = flow(files)
        await adding.load()
        let defaultRoot = try root(adding, "/home/dev/.claude")
        await adding.review(defaultRoot, adding: true)
        await adding.accept(defaultRoot)
        #expect(adding.states[defaultRoot.id] == .read(.on))

        // A new flow knows nothing of that edit, as on another device.
        let removing = flow(files)
        await removing.load()
        await removing.review(try root(removing, "/home/dev/.claude"), adding: false)
        guard case .review(let change, adding: false) = removing.states[defaultRoot.id] else {
            Issue.record("expected a review, got \(String(describing: removing.states[defaultRoot.id]))")
            return
        }
        #expect(change.shownLines.contains { $0.kind == .removed && $0.text.contains(ClaudeCodeHooks.marker) })
        await removing.accept(defaultRoot)

        #expect(await files.files[Self.defaultSettings] == before)
        #expect(removing.states[defaultRoot.id] == .read(.off))
    }

    @Test func aFileHeelerWontChangeSaysWhyAndWritesNothing() async throws {
        let odd = Data("{ // mine\n}\n".utf8)
        let files = InMemoryHostFiles(files: [Self.defaultSettings: odd])
        let placements = Placements()
        let flow = flow(files, placements: placements)
        await flow.load()
        let defaultRoot = try root(flow, "/home/dev/.claude")
        #expect(flow.states[defaultRoot.id] == .read(nil))

        await flow.review(defaultRoot, adding: true)

        guard case .refused = flow.states[defaultRoot.id] else {
            Issue.record("expected a refusal, got \(String(describing: flow.states[defaultRoot.id]))")
            return
        }
        #expect(placements.count == 0)
        #expect(await files.files[Self.defaultSettings] == odd)
    }

    @Test func aFileChangedAfterTheReviewIsNotWritten() async throws {
        let files = InMemoryHostFiles(files: [Self.defaultSettings: Data("{}\n".utf8)])
        let flow = flow(files)
        await flow.load()
        let defaultRoot = try root(flow, "/home/dev/.claude")
        await flow.review(defaultRoot, adding: true)
        await files.set(Self.defaultSettings, Data("{\"model\": \"opus\"}\n".utf8))

        await flow.accept(defaultRoot)

        #expect(flow.states[defaultRoot.id] == .failed(HarnessConfigEditMessage.text(for: HarnessConfigEditError.changedSinceRead)))
        #expect(await files.files[Self.defaultSettings] == Data("{\"model\": \"opus\"}\n".utf8))
        await flow.dismiss(defaultRoot)
        #expect(flow.states[defaultRoot.id] == .read(.off))
    }

    @Test func aHostThatCanNotSayWhereItsFilesAreFails() async {
        let flow = ClaudeCodeHooksFlow(
            services: { InMemoryHostFiles() },
            locate: { throw TransportError.sshUnreachable(detail: "The Host is not connected.") },
            place: {})
        await flow.load()
        guard case .failed = flow.phase else {
            Issue.record("expected a failure, got \(flow.phase)")
            return
        }
        #expect(flow.roots.isEmpty)
    }

    @Test func hostDetailListsEachClaudeCodeAccountAddedOnATmuxHost() async throws {
        let tmux = ScriptedTmuxHost()
        let host = Host(
            address: "mac.example", username: "dev", serverKind: .tmux,
            sessionName: "work", tmuxPaths: ScriptedTmuxHost.paths("work"))
        await tmux.startServer("work")
        let dataHome = await tmux.dataHome
        await tmux.helper.seedFolder("\(dataHome)/heeler/host-helper", mode: 0o700)

        let console = ConsoleStore(
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not under test") },
                    keepalive: nil)
            },
            connectTmux: { host in
                await tmux.transport(socketName: host.tmuxSocketName, storedPaths: host.storedTmuxPaths)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths) },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: nil)
            })
        console.setHosts([host])
        await console.resume()
        defer { console.setHosts([]) }

        for _ in 0..<200 where console.hostStatuses[host.id] != .connected {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(console.hostStatuses[host.id] == .connected)

        let installer = HostHelperInstaller(
            host: tmux, bundle: { HostHelperFixture.bundle() }, healthGap: {})
        _ = try await installer.install(
            over: try await installer.read(), bundle: HostHelperFixture.bundle(),
            tmuxPaths: ScriptedTmuxHost.paths())

        let accounts = console.hostAccountsStore(for: host.id)
        try await accounts.load()
        let workAccount = try JSONDecoder().decode(
            AgentUsageReport.AccountSuggestion.self,
            from: Data(#"{"directory":"/Users/dev/.claude-work","name":"Work","source":"agent"}"#.utf8))
        let personalAccount = try JSONDecoder().decode(
            AgentUsageReport.AccountSuggestion.self,
            from: Data(#"{"directory":"/Users/dev/.claude-personal","name":"Personal","source":"agent"}"#.utf8))
        #expect(await accounts.add(workAccount, for: .claude))
        #expect(await accounts.add(personalAccount, for: .claude))

        let flow = console.claudeCodeHooksFlow(on: host.id)
        await flow.load()

        #expect(flow.phase == .loaded)
        #expect(!flow.accountsUnreadable)
        #expect(flow.roots == [
            .init(accountName: nil, path: "/Users/dev/.claude"),
            .init(accountName: "Work", path: "/Users/dev/.claude-work"),
            .init(accountName: "Personal", path: "/Users/dev/.claude-personal"),
        ])
    }

    @Test func firstLoadKeepsLoadingPhaseUntilEveryRootIsRead() async throws {
        let files = InMemoryHostFiles(files: [
            Self.accountFile: try accounts(),
            Self.defaultSettings: ClaudeCodeHooks.launchSettings(script: Self.script),
        ])
        let entered = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        await files.onRead(of: Self.defaultSettings) { _ in
            entered.continuation.yield()
            entered.continuation.finish()
            for await _ in release.stream { break }
        }
        let flow = flow(files)

        let loading = Task { await flow.loadIfNeeded() }
        for await _ in entered.stream { break }

        #expect(flow.phase == .loading)

        release.continuation.yield()
        release.continuation.finish()
        await loading.value

        #expect(flow.phase == .loaded)
        #expect(flow.states["/home/dev/.claude"] == .read(.on))
        #expect(flow.states[Self.work] == .read(.off))
    }

    @Test func cancelledReadsNeverShowAsFailuresAndReloadShowsRealStates() async throws {
        let files = InMemoryHostFiles(files: [
            Self.accountFile: try accounts(),
            Self.defaultSettings: ClaudeCodeHooks.launchSettings(script: Self.script),
        ])
        let flow = flow(files)

        await files.onRead(of: Self.accountFile) { _ in
            throw TransportError.cancelled
        }
        await flow.loadIfNeeded()
        #expect(flow.phase == .loading)
        #expect(!flow.accountsUnreadable)
        #expect(flow.states.isEmpty)

        await files.onRead(of: Self.defaultSettings) { _ in
            throw TransportError.cancelled
        }
        await flow.loadIfNeeded()
        #expect(flow.phase == .loading)
        #expect(!flow.accountsUnreadable)
        #expect(flow.states.isEmpty)

        let entered = AsyncStream.makeStream(of: Void.self)
        let release = AsyncStream.makeStream(of: Void.self)
        await files.onRead(of: Self.defaultSettings) { _ in
            entered.continuation.yield()
            entered.continuation.finish()
            for await _ in release.stream { break }
        }
        let firstVisit = Task { await flow.loadIfNeeded() }
        for await _ in entered.stream { break }
        firstVisit.cancel()
        let secondVisit = Task { await flow.loadIfNeeded() }
        release.continuation.finish()
        await firstVisit.value
        await secondVisit.value

        #expect(flow.phase == .loaded)
        #expect(!flow.accountsUnreadable)
        #expect(flow.states["/home/dev/.claude"] == .read(.on))
        #expect(flow.states[Self.work] == .read(.off))

        let work = try root(flow, Self.work)
        await files.onRead(of: "\(Self.work)/settings.json") { _ in
            throw TransportError.cancelled
        }
        await flow.review(work, adding: true)
        #expect(flow.states[work.id] == .read(.off))

        await flow.review(work, adding: true)
        guard case .review = flow.states[work.id] else {
            Issue.record("expected a review, got \(String(describing: flow.states[work.id]))")
            return
        }
        await files.onRead(of: "\(Self.work)/settings.json") { _ in
            throw TransportError.cancelled
        }
        await flow.dismiss(work)
        #expect(flow.states[work.id] == .reading)

        await flow.loadIfNeeded()
        #expect(flow.states[work.id] == .read(.off))
    }

    @Test func sectionFirstOpenInAFormShowsEachRootsRealState() async throws {
        let files = InMemoryHostFiles(files: [
            Self.accountFile: try accounts(),
            Self.defaultSettings: ClaudeCodeHooks.launchSettings(script: Self.script),
        ])
        await files.onRead(of: Self.defaultSettings) { _ in
            try await Task.sleep(for: .milliseconds(30))
        }
        await files.onRead(of: "\(Self.work)/settings.json") { _ in
            try await Task.sleep(for: .milliseconds(30))
        }
        let flow = flow(files)
        let controller = UIHostingController(rootView: Form { ClaudeCodeHooksSection(flow: flow) })

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            for _ in 0..<200 where flow.phase != .loaded {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(flow.phase == .loaded)
            #expect(flow.states["/home/dev/.claude"] == .read(.on))
            #expect(flow.states[Self.work] == .read(.off))

            let labels = AccessibilityProbe.labels(in: window)
            #expect(!labels.contains { $0.contains("Connection cancelled") }, "\(labels)")
            #expect(labels.contains { $0.contains("On") }, "\(labels)")
            #expect(labels.contains { $0.contains("Off") }, "\(labels)")
        }
    }
}
