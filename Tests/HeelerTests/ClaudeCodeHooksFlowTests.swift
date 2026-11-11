import Foundation
import Testing

@testable import Heeler

/// Host detail's Claude Code hooks on a tmux Host (ADR 0044): the default root
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
}
