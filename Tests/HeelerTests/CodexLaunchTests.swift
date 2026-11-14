import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Codex launch")
struct CodexLaunchTests {
    private static func info(_ processes: [PaneProcessInfoProcess]) -> PaneProcessInfo {
        PaneProcessInfo(paneID: "w1:p1", foregroundProcesses: processes)
    }

    private static func codex(_ arguments: [String]?, name: String = "codex", argv0: String? = nil)
        -> PaneProcessInfoProcess
    {
        PaneProcessInfoProcess(name: name, pid: 7, argv: arguments, argv0: argv0)
    }

    @Test(arguments: [
        ["codex"], ["codex", "resume"], ["codex", "--yolo", "-m", "gpt-5", "-s", "workspace-write"],
        ["codex", "--enable", "web_search_request"], ["codex", "--", "-c is part of the prompt"],
        ["codex", "--remote", "unix://"], ["codex", "--remote=unix:///home/dev/.codex/app-server-control/app-server-control.sock"],
        ["codex", "agents"], ["codex", "fix the failing test"],
    ])
    func aLaunchWithoutAnOwnServerOptionUsesTheSharedServer(arguments: [String]) {
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([Self.codex(arguments)])) == true)
    }

    @Test(arguments: [
        ["codex", "--no-daemon"], ["codex", "resume", "--no-daemon"], ["codex", "--oss"],
        ["codex", "--strict-config"], ["codex", "--dangerously-bypass-hook-trust"], ["codex", "--search"],
        ["codex", "--config", "model=o3"], ["codex", "-cmodel=o3"], ["codex", "-p", "work"],
        ["codex", "--approve-for-me"], ["codex", "resume", "--not-so-yolo"],
        ["codex", "--remote", "ws://127.0.0.1:4500"], ["codex", "--remote=unix:///tmp/other.sock"],
    ])
    func anOwnServerOptionKeepsCodexOffTheSharedServer(arguments: [String]) {
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([Self.codex(arguments)])) == false)
    }

    /// npm's Node launcher passes the native binary the same arguments; only
    /// the binary counts, found by its name or its argv0.
    @Test func theNativeBinaryDecidesForItsLauncher() {
        let launcher = PaneProcessInfoProcess(
            name: "node", pid: 6, argv: ["node", "/usr/lib/node_modules/@openai/codex/bin/codex.js"])
        let binary = Self.codex(
            ["codex", "--no-daemon"], name: "codex-aarch64-apple-darwin",
            argv0: "/usr/lib/node_modules/@openai/codex/vendor/aarch64-apple-darwin/codex/codex")
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([launcher, binary])) == false)
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([launcher])) == nil)
    }

    /// On Linux herdr reports no argv0 and a name cut to 15 bytes.
    @Test func argvZeroNamesCodexOnLinux() {
        let process = PaneProcessInfoProcess(
            name: "codex-x86_64-un", pid: 7, argv: ["/opt/codex/bin/codex", "resume"])
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([process])) == true)
    }

    @Test(arguments: [["codex", "exec", "fix it"], ["codex", "e", "fix it"], ["codex", "app-server"]])
    func aSubcommandWithoutTheTerminalUISaysNothing(arguments: [String]) {
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([Self.codex(arguments)])) == nil)
    }

    @Test func noCodexWithKnownArgumentsSaysNothing() {
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([])) == nil)
        #expect(CodexLaunch.launchesOnSharedServer(PaneProcessInfo(paneID: "w1:p1")) == nil)
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([Self.codex(nil)])) == nil)
        #expect(CodexLaunch.launchesOnSharedServer(Self.info([Self.codex([])])) == nil)
        #expect(
            CodexLaunch.launchesOnSharedServer(
                foreground: HerdrCoreForeground(pid: 7, name: "codex", argv: [], cwd: "/work/app")) == nil)
        #expect(
            CodexLaunch.launchesOnSharedServer(Self.info([PaneProcessInfoProcess(name: "zsh", pid: 1, argv: ["zsh"])]))
                == nil)
    }

    @Test func theControlSocketIsUnderTheDefaultCodexHome() {
        #expect(
            CodexLaunch.controlSocketPath(home: "/home/dev")
                == "/home/dev/.codex/app-server-control/app-server-control.sock")
    }

    @Test func onlyAWaitingCodexTurnsIntoTheNotice() {
        let waiting = ChatUnavailableReason.noSession(.codex)
        #expect(waiting.title(launchNotice: nil) == "Waiting for Conversation")
        #expect(waiting.explanation(launchNotice: nil) == waiting.explanation)
        #expect(waiting.launchNotice(nil) == nil)
        #expect(waiting.guideURL(launchNotice: nil) == nil)

        #expect(waiting.title(launchNotice: .codexSharedServer).hasPrefix("Codex Started Without"))
        let noticeExplanation = waiting.explanation(launchNotice: .codexSharedServer)
        #expect(noticeExplanation.contains("codex \(ChatLaunchNotice.unbrokenNoDaemon) resume"))
        #expect(!noticeExplanation.contains("daemon stop"))
        let expectedGuideURL =
            "https://docs.heeler.bybee.dev/chat-troubleshooting#codex-started-without---no-daemon"
        #expect(waiting.launchNotice(.codexSharedServer)?.guideURL?.absoluteString == expectedGuideURL)
        #expect(waiting.guideURL(launchNotice: .codexSharedServer)?.absoluteString == expectedGuideURL)
        #expect(ChatUnavailableReason.codexSharedDaemon.guideURL(launchNotice: nil)?.absoluteString == expectedGuideURL)

        for other in [ChatUnavailableReason.notFound(searchedAll: true), .noSession(.claude)] {
            #expect(other.title(launchNotice: .codexSharedServer) == other.title)
            #expect(other.explanation(launchNotice: .codexSharedServer) == other.explanation)
            #expect(other.launchNotice(.codexSharedServer) == nil)
            #expect(other.guideURL(launchNotice: .codexSharedServer) == nil)
        }
    }

    @MainActor
    @Test func theUnavailableViewRendersTrimmedCopyAndLearnMoreLink() async throws {
        let noticeLabels = try await labels(
            of: ChatUnavailableView(
                reason: .noSession(.codex), launchNotice: .codexSharedServer,
                retry: {}, showAgentTerminal: {}),
            showing: "Learn More")
        let normalizedNotice = noticeLabels.map(Self.normalizeCommandSpaces)
        #expect(normalizedNotice.contains { $0.contains("Codex Started Without") }, "\(noticeLabels)")
        #expect(normalizedNotice.contains { $0.contains("codex --no-daemon resume") }, "\(noticeLabels)")
        #expect(!normalizedNotice.contains { $0.contains("daemon stop") }, "\(noticeLabels)")
        #expect(normalizedNotice.contains("Show Agent Terminal"), "\(noticeLabels)")
        #expect(normalizedNotice.contains("Check Again"), "\(noticeLabels)")
        #expect(normalizedNotice.contains("Learn More"), "\(noticeLabels)")

        let daemonLabels = try await labels(
            of: ChatUnavailableView(
                reason: .codexSharedDaemon, retry: {}, showAgentTerminal: {}),
            showing: "Learn More")
        let normalizedDaemon = daemonLabels.map(Self.normalizeCommandSpaces)
        #expect(normalizedDaemon.contains { $0.contains("codex resume --no-daemon") }, "\(daemonLabels)")
        #expect(!normalizedDaemon.contains { $0.contains("daemon stop") }, "\(daemonLabels)")
        #expect(normalizedDaemon.contains("Show Agent Terminal"), "\(daemonLabels)")
        #expect(normalizedDaemon.contains("Check Again"), "\(daemonLabels)")
        #expect(normalizedDaemon.contains("Learn More"), "\(daemonLabels)")
    }

    @MainActor
    @Test func checkAgainHoldWaitsForMinimumAndEndsAtAnswerOrLimit() async {
        let clock = ContinuousClock()
        var answered = true
        let quickStart = clock.now
        await AgentChatSurfaceView.ChatCheckAgainHold.wait(
            minimum: .milliseconds(80), limit: .milliseconds(400), poll: .milliseconds(10),
            until: { answered })
        #expect(quickStart.duration(to: clock.now) >= .milliseconds(70))

        answered = false
        let limitStart = clock.now
        await AgentChatSurfaceView.ChatCheckAgainHold.wait(
            minimum: .milliseconds(40), limit: .milliseconds(160), poll: .milliseconds(10),
            until: { answered })
        let limitElapsed = limitStart.duration(to: clock.now)
        #expect(limitElapsed >= .milliseconds(140))
        #expect(limitElapsed < .milliseconds(350))
    }

    private static func normalizeCommandSpaces(_ value: String) -> String {
        value.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2011}", with: "-")
            .replacingOccurrences(of: "\u{2060}", with: "")
    }

    @MainActor
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
}
