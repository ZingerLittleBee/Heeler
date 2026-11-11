import Foundation
import Testing

@testable import Heeler

/// The leaked-environment notice through `ConsoleStore` over a scripted
/// tmux Host (ADR 0034, ADR 0043). The planted lines carry values; the
/// published result is names only.
@MainActor
@Suite("tmux environment in the Console", .timeLimit(.minutes(1)))
struct TmuxEnvironmentConsoleTests {
    private let host = Host(
        address: "mac.example", username: "dev", serverKind: .tmux, tmuxPaths: ScriptedTmuxHost.paths())
    private let suiteName = "tmux-environment-\(UUID().uuidString)"
    private let secret = "secret-child-token"

    private func device() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: suiteName))
    }

    private func launch(on defaults: UserDefaults, over tmux: ScriptedTmuxHost) async throws -> ConsoleStore {
        let store = ConsoleStore(
            pins: PinnedAgentsStore(defaults: defaults),
            makeSession: { _, subscriptions in
                EventsSession(
                    subscriptions: subscriptions,
                    connect: { throw TransportError.sshUnreachable(detail: "not a Herdr TUI Host") },
                    keepalive: nil)
            },
            makeTmuxSession: { host in
                TmuxHostSession(
                    storedPaths: host.storedTmuxPaths,
                    connect: { paths in
                        await tmux.transport(socketName: host.tmuxSocketName, storedPaths: paths)
                    },
                    reconnectPolicy: ReconnectPolicy(
                        initialDelay: .milliseconds(10), multiplier: 1, maxDelay: .milliseconds(10)),
                    keepalive: KeepalivePolicy(interval: .milliseconds(10)))
            },
            coreHostMemory: HerdrCoreHostMemory(defaults: defaults))
        store.setHosts([host])
        await store.resume()
        return store
    }

    private func waitUntil(
        _ what: String, _ condition: @MainActor () async -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<500 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for \(what)", sourceLocation: sourceLocation)
    }

    private func published(_ store: ConsoleStore) -> String {
        let notice = store.hostCoreEnvironmentNotices[host.id]
        return [
            notice?.variables.map(\.name).joined(separator: "\n") ?? "",
            notice?.variables.map(\.breaks).joined(separator: "\n") ?? "",
        ].joined(separator: "\n")
    }

    @Test func hostDetailShowsLeakedNames() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([
            .make(session: 0, sessionName: "main", pane: 1),
            .make(session: 2, sessionName: "api", pane: 2),
            .make(session: 9, sessionName: "heeler", pane: 9, attachMark: "attach"),
        ])
        await tmux.setGlobalEnvironment([
            "CLAUDECODE=\(secret)",
            "CLAUDE_CONFIG_DIR=/secret/claude",
            "XDG_CONFIG_HOME=/secret/xdg",
            "PATH=/usr/bin",
        ])
        await tmux.setSessionEnvironment(
            [
                "CODEX_THREAD_ID=secret-thread",
                "CODEX_HOME=/secret/codex",
                "-CLAUDE_CONFIG_DIR",
                "-CLAUDECODE",
            ], session: "$0")
        await tmux.setSessionEnvironment(
            ["TMUX=/secret/tmux", "PI_PROGRAM_STATUS=0"], session: "$9")
        let store = try await launch(on: try device(), over: tmux)
        defer { store.setHosts([]) }

        try await waitUntil("the notice") { store.hostCoreEnvironmentNotices[self.host.id] != nil }
        let notice = try #require(store.hostCoreEnvironmentNotices[host.id])
        #expect(notice.variables.map(\.name) == ["CLAUDECODE", "CODEX_THREAD_ID"])
        #expect(
            notice.variables.first { $0.name == "CLAUDECODE" }?.breaks
                == "Programs here read as started from inside Claude Code, which can change what they report and record.")
        #expect(!published(store).contains(secret))
        #expect(!published(store).contains("/secret"))

        let commands = await tmux.commands
        #expect(commands.contains { $0.contains("show-environment -g") })
        #expect(commands.contains { $0.contains("show-environment -t '$0'") })
        #expect(commands.contains { $0.contains("show-environment -t '$2'") })
        #expect(!commands.contains { $0.contains("show-environment") && $0.contains("main") })
        #expect(!commands.contains { $0.contains("show-environment -t '$9'") })

        let before = commands.count
        await tmux.setSessionEnvironment(["CODEX_HOME=/secret/later"], session: "$4")
        await tmux.changePanes { panes in
            panes.append(.make(session: 4, sessionName: "later", pane: 4))
        }
        try await waitUntil("the new session") {
            let commands = await tmux.commands
            return commands.dropFirst(before).contains { $0.contains("show-environment -t '$4'") }
        }
        #expect(!published(store).contains(secret))
    }

    @Test func suspendingClearsTheEnvironment() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(session: 0, sessionName: "main")])
        await tmux.setGlobalEnvironment(["TMUX=\(secret)", "CLAUDE_CONFIG_DIR=/secret/claude"])
        let store = try await launch(on: try device(), over: tmux)
        defer { store.setHosts([]) }
        try await waitUntil("the notice") { store.hostCoreEnvironmentNotices[self.host.id] != nil }

        await store.suspend()
        try await waitUntil("the notice to clear") { store.hostCoreEnvironmentNotices[self.host.id] == nil }
        #expect(!published(store).contains(secret))
    }

    @Test func aFailedReadShowsNothingUntilTheNextInventory() async throws {
        let tmux = ScriptedTmuxHost()
        await tmux.setPanes([.make(session: 0, sessionName: "main")])
        await tmux.setGlobalEnvironment(["TMUX=\(secret)", "CODEX_HOME=/secret/codex"])
        await tmux.failShowEnvironment(true)
        let store = try await launch(on: try device(), over: tmux)
        defer { store.setHosts([]) }

        try await waitUntil("the failed ask") {
            await tmux.commands.contains { $0.contains("show-environment -g") }
        }
        try await waitUntil("the inventory") { store.hostsAwaitingSnapshot.isEmpty }
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.hostCoreEnvironmentNotices[host.id] == nil)
        #expect(store.hostStatuses[host.id] == .connected)

        await tmux.failShowEnvironment(false)
        await tmux.changePanes { panes in
            panes.append(.make(session: 0, sessionName: "main", window: 1, pane: 3))
        }
        try await waitUntil("the notice") { store.hostCoreEnvironmentNotices[self.host.id] != nil }
        #expect(store.hostCoreEnvironmentNotices[host.id]?.variables.map(\.name) == ["TMUX"])
        #expect(!published(store).contains(secret))
    }
}
