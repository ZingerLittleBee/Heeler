import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Codex session settings", .serialized)
struct CodexSessionSettingsTests {
    private let idle = ChatProjectionContext(activity: .idle)

    @Test("Captured Codex probes surface their recorded model and reasoning effort")
    func probeModelAndEffort() throws {
        let probe1 = try CodexProbe.probe1()
        // P1 starts at low (L8), then switches to medium at L48 when entering Plan Mode.
        let p1Early = probe1.reducer(Array(probe1.lines.prefix(35))).transcript(idle)
        #expect(p1Early.model == "gpt-6.1-sol")
        #expect(p1Early.effort == "low")
        let t1 = probe1.reducer().transcript(idle)
        #expect(t1.model == "gpt-6.1-sol")
        #expect(t1.effort == "medium")
        #expect(t1.diagnostics == ChatTranscriptDiagnostics())

        let probe2 = try CodexProbe.probe2()
        // P2 starts at low, switches to medium at L37, and returns to low at L54.
        let early = probe2.reducer(Array(probe2.lines.prefix(25))).transcript(idle)
        #expect(early.model == "gpt-6.1-sol")
        #expect(early.effort == "low")

        let mid = probe2.reducer(Array(probe2.lines.prefix(45))).transcript(idle)
        #expect(mid.model == "gpt-6.1-sol")
        #expect(mid.effort == "medium")

        let full = probe2.reducer().transcript(idle)
        #expect(full.model == "gpt-6.1-sol")
        #expect(full.effort == "low")
        #expect(full.diagnostics == ChatTranscriptDiagnostics())
    }

    @Test("Turn context and thread settings update model and effort while ignoring reviewer turns")
    func rolloutSettingsAndReviewerForwarding() {
        var builder = CodexRolloutBuilder()
        builder.turnStarted("t1")
        builder.record("turn_context", ["turn_id": "t1", "model": "gpt-6.1-sol", "effort": "high"])
        builder.userMessage("t1", id: "u1", text: "review this")
        // A reviewer turn writes its own `turn_context` (even ahead of `turn_started`)
        // under its own turn id while forwarding into `t1`; it must not replace the thread's model.
        builder.record("turn_context", ["turn_id": "rev-1", "model": "codex-auto-review", "effort": "low"])
        builder.event("task_started", [("turn_id", "rev-1"), ("root_turn_id", "t1")])
        builder.agentMessage("rev-1", id: "a1", text: "Looks good")
        builder.turnComplete("rev-1")
        builder.turnComplete("t1")

        let afterReview = builder.reducer().transcript(idle)
        #expect(afterReview.model == "gpt-6.1-sol")
        #expect(afterReview.effort == "high")

        // Idle `/model` switch with large trailing instructions truncated by the line framer.
        let instructions = String(repeating: "x", count: 40_000)
        builder.event(
            "thread_settings_applied",
            [
                (
                    "thread_settings",
                    [
                        "model": "gpt-6-luna",
                        "reasoning_effort": "xhigh",
                        "collaboration_mode": ["settings": ["developer_instructions": .string(instructions)]],
                    ]
                )
            ])
        var truncatedReducer = CodexRolloutReducer(rolloutID: "r1")
        truncatedReducer.append(JSONLLineFramer.lines(in: builder.data, lineCap: 32 * 1_024, prefixCap: 16 * 1_024))
        let afterTruncatedSwitch = truncatedReducer.transcript(idle)
        #expect(afterTruncatedSwitch.model == "gpt-6-luna")
        #expect(afterTruncatedSwitch.effort == "xhigh")
        #expect(afterTruncatedSwitch.diagnostics == ChatTranscriptDiagnostics())

        // Switching to a model with `"none"` effort clears the previous effort.
        builder.turnStarted("t2")
        builder.record("turn_context", ["turn_id": "t2", "model": "custom/non-reasoning", "effort": "none"])
        builder.turnComplete("t2")
        let cleared = builder.reducer().transcript(idle)
        #expect(cleared.model == "custom/non-reasoning")
        #expect(cleared.effort == nil)
    }

    @Test("Legacy rollouts also surface turn_context model and effort")
    func legacyRolloutSettings() {
        var builder = CodexRolloutBuilder(.legacy)
        builder.record("turn_context", ["model": "gpt-5.6-sol", "effort": "medium"])
        builder.legacyUser("hi")
        builder.legacyAgent("hello")
        let transcript = builder.reducer().transcript(idle)
        #expect(transcript.model == "gpt-5.6-sol")
        #expect(transcript.effort == "medium")
    }

    @Test("Model catalog sorts by priority, hides non-list models, and falls back when absent")
    func modelCatalogDecodeAndRead() async throws {
        let raw = """
        {
          "fetched_at": "2026-11-14T00:00:00Z",
          "models": [
            {
              "slug": "gpt-5.6-luna",
              "display_name": "GPT-5.6-Luna",
              "priority": 20,
              "visibility": "list",
              "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]
            },
            {
              "slug": "codex-auto-review",
              "display_name": "Codex Auto Review",
              "priority": 1,
              "visibility": "hide",
              "supported_reasoning_levels": [{"effort": "low"}]
            },
            {
              "slug": "gpt-6.1-sol",
              "display_name": "GPT-6.1-Sol",
              "priority": 2,
              "visibility": "list",
              "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}, {"effort": "max"}]
            },
            {
              "slug": "ollama/qwen3",
              "priority": 20
            }
          ]
        }
        """
        let catalog = try #require(CodexModelCatalog.decode(Data(raw.utf8)))
        #expect(catalog.choices.map(\.id) == ["gpt-6.1-sol", "gpt-5.6-luna", "ollama/qwen3"])
        #expect(catalog.choices.map(\.title) == ["GPT-6.1-Sol", "GPT-5.6-Luna", "ollama/qwen3"])
        #expect(catalog.displayTitle(for: "codex-auto-review") == "Codex Auto Review")
        #expect(catalog.displayTitle(for: "gpt-5.3-codex") == "GPT-5.3-Codex")
        #expect(catalog.selectedChoiceID(for: "GPT-6.1-Sol") == "gpt-6.1-sol")
        #expect(catalog.selectedChoiceID(for: "gpt-5.6-luna") == "gpt-5.6-luna")
        #expect(catalog.effortChoices(for: "GPT-5.6-Luna") == ["low", "high"])
        #expect(catalog.effortChoices(for: "ollama/qwen3") == CodexModelCatalog.defaultEfforts)
        #expect(CodexModelCatalog.decode(Data("{}".utf8)) == nil)

        let files = VirtualHostFiles()
        #expect(try await CodexModelCatalog.read(files: files.hostFiles()) == nil)
        await files.write(Data(raw.utf8), at: "/home/dev/.codex/models_cache.json")
        let loaded = try await CodexModelCatalog.read(files: files.hostFiles())
        #expect(loaded == catalog)
    }

    @Test("Screen footer reader handles 0.160 and 0.169 layouts and skips startup or truncated rows")
    func screenFooterAndStartupGuard() throws {
        let ready = try ScreenFixture.screen("codex-00-ready")
        let parsedReady = try #require(CodexSessionScreen.footerSettings(onScreen: ready))
        #expect(parsedReady.model == "GPT-6.1-Sol")
        #expect(parsedReady.effort == "low")

        let phone = try ScreenFixture.screen("codex-18-x7-phone-async-countdown")
        let parsedPhone = try #require(CodexSessionScreen.footerSettings(onScreen: phone))
        #expect(parsedPhone.model == "GPT-6.1-Sol")
        #expect(parsedPhone.effort == "low")

        // Codex 0.169+ layout with Fast mode enabled and a multi-line draft above it.
        let fastScreen = ANSIScreenDecoder.decode([
            "\u{1B}[1m›\u{1B}[0m first line of draft",
            "  second line of draft",
            "",
            "  GPT-6.1 Terra xhigh Fast · ~/repo · 98% left",
        ].joined(separator: "\r\n"))
        let parsedFast = try #require(CodexSessionScreen.footerSettings(onScreen: fastScreen))
        #expect(parsedFast.model == "GPT-6.1 Terra")
        #expect(parsedFast.effort == "xhigh")

        // Truncated model name must not be guessed.
        let truncated = ANSIScreenDecoder.decode([
            "\u{1B}[1m›\u{1B}[0m \u{1B}[2mAsk Codex to do anything\u{1B}[0m",
            "",
            "  GPT-6.1-S… · ~/repo",
        ].joined(separator: "\r\n"))
        #expect(CodexSessionScreen.footerSettings(onScreen: truncated) == nil)

        // Startup screen blocks sending and yields no footer model.
        let startup = ANSIScreenDecoder.decode([
            "\u{1B}[1m›\u{1B}[0m \u{1B}[2mAsk Codex to do anything\u{1B}[0m",
            "",
            "  Waiting for startup · esc cancel",
        ].joined(separator: "\r\n"))
        #expect(CodexSessionScreen.footerSettings(onScreen: startup) == nil)
        #expect(InputBoxStateDetector.detect(startup, program: .codex) == .overlay("Waiting for startup · esc cancel"))
    }

    @Test("Switch outcome detects confirmations, scrolled full screens, and wrapped errors")
    func switchOutcomeDetection() {
        func codexScreen(_ above: [String], draft: String? = nil) -> ANSIScreen {
            let prompt = draft.map { "\u{1B}[1m›\u{1B}[0m \($0)" }
                ?? "\u{1B}[1m›\u{1B}[0m \u{1B}[2mAsk Codex to do anything\u{1B}[0m"
            return ANSIScreenDecoder.decode((above + ["", prompt, "", "  GPT-6.1-Sol medium · ~/proj"]).joined(separator: "\r\n"))
        }

        let before = codexScreen(["• Model changed to gpt-6.1-sol medium for this session only"])
        // Command still sitting in the composer is not answered yet.
        let unsubmitted = codexScreen(
            ["• Model changed to gpt-6.1-sol medium for this session only"],
            draft: "/model gpt-6.1-sol")
        #expect(CodexSessionScreen.switchOutcome(since: before, command: "/model gpt-6.1-sol", on: unsubmitted) == nil)

        // Full screen scrolled the old confirmation off and printed the same notice again.
        let fullBefore = codexScreen(["• Earlier reply", "• Model changed to gpt-6.1-sol medium for this session only"])
        let fullAfter = codexScreen([
            "• Model changed to gpt-6.1-sol medium for this session only",
            "• Model changed to gpt-6.1-sol medium for this session only",
        ])
        #expect(
            CodexSessionScreen.switchOutcome(since: fullBefore, command: "/model gpt-6.1-sol", on: fullAfter)
                == .changed(model: "gpt-6.1-sol", effort: "medium"))

        // Wrapped error bullet joins continuation lines.
        let failed = codexScreen([
            "• Model changed to gpt-6.1-sol medium for this session only",
            "■ Reasoning level 'ultra' is unavailable",
            "  for gpt-5.5.",
        ])
        #expect(
            CodexSessionScreen.switchOutcome(since: before, command: "/model --reasoning=ultra", on: failed)
                == .failed("Reasoning level 'ultra' is unavailable for gpt-5.5."))
    }

    @Test("Effort override clears when a subsequent turn switches models with the same effort")
    @MainActor func coupledModelAndEffortOverrides() {
        let overrides = AgentSettingOverrides()
        let before: [String?] = [nil, "gpt-6.1-sol", "high"]
        overrides.set(.model, "gpt-6-luna", over: before)
        overrides.set(.effort, "medium", over: before)
        #expect(overrides.value(.model, over: before) == "gpt-6-luna")
        #expect(overrides.value(.effort, over: before) == "medium")

        // Terminal switches to gpt-5.5 at high: effort matches `before[2]`, but model changed,
        // so the stale `medium` override must yield to the new turn's `high`.
        let nextTurn: [String?] = [nil, "gpt-5.5", "high"]
        #expect(overrides.value(.model, over: nextTurn) == nil)
        #expect(overrides.value(.effort, over: nextTurn) == nil)
    }

    @Test("A Codex Chat header loads models_cache.json, omits Claude permission chrome, and switches model and effort")
    @MainActor func hostedCodexHeaderSwitchesModelAndEffort() async throws {
        let host = Host.fixture()
        let sessionID = "01a10fc8-07f3-7c90-b745-fa302f852394"
        let info = AgentInfo(
            agentStatus: .idle, focused: false, paneID: "w1:p1", revision: 1,
            tabID: "t1", terminalID: "term-1", workspaceID: "w1", agent: "codex",
            agentSession: .init(agent: "codex", kind: .id, source: "herdr:codex", value: sessionID),
            cwd: "/home/dev/proj")
        let transport = ScriptedTransport(snapshot: .fixture(agents: [info]))
        let files = VirtualHostFiles()
        let cacheJSON = """
        {
          "models": [
            {
              "slug": "gpt-6.1-sol",
              "display_name": "GPT-6.1-Sol",
              "priority": 1,
              "visibility": "list",
              "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}, {"effort": "high"}]
            },
            {
              "slug": "gpt-6-luna",
              "display_name": "GPT-6-Luna",
              "priority": 2,
              "visibility": "list",
              "supported_reasoning_levels": [{"effort": "low"}, {"effort": "high"}]
            }
          ]
        }
        """
        await files.write(Data(cacheJSON.utf8), at: "/home/dev/.codex/models_cache.json")
        await transport.scriptChat(files: files.hostFiles(), agent: Agent(info))

        func renderPane(history: [String], draft: String? = nil, footerModel: String = "GPT-6.1-Sol medium") -> String {
            let prompt = draft.map { "\u{1B}[1m›\u{1B}[0m \($0)" }
                ?? "\u{1B}[1m›\u{1B}[0m \u{1B}[2mAsk Codex to do anything\u{1B}[0m"
            return (history + ["", prompt, "", "  \(footerModel) · ~/proj"]).joined(separator: "\r\n")
        }

        await transport.setPaneText(renderPane(history: ["  OpenAI Codex (v0.169.0)"]), paneID: info.paneID)

        let console = ConsoleStore(chatCache: VolatileChatTranscriptCache()) { _, subscriptions in
            EventsSession(subscriptions: subscriptions, connect: { transport }, keepalive: nil)
        }
        console.setHosts([host])
        defer { console.setHosts([]) }
        await console.resume()

        var budget = PollBudget(.seconds(5))
        while console.agents.isEmpty, budget.hasTimeLeft {
            try await Task.sleep(for: .milliseconds(10))
            budget.charge()
        }
        let agent = try #require(console.agents.first)
        let suite = "codex-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "agent.back-header-expanded")

        let controller = UIHostingController(rootView: NavigationStack {
            HerdrCoreChatTests.chatDetail(of: agent, console: console, defaults: defaults)
                .defaultAppStorage(defaults)
        })

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 874), rootViewController: controller
        ) { window in
            var budget = PollBudget(.seconds(3))
            while budget.hasTimeLeft {
                if accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == "GPT-6.1-Sol · medium",
                    let menu = try? await HostedMenu.items(labeled: "Agent settings", in: window),
                    menu.flatMap({ $0 }) == ["GPT-6.1-Sol", "GPT-6-Luna", "low", "medium", "high"]
                {
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
                budget.charge()
            }
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == "GPT-6.1-Sol · medium")
            // Codex must not show Claude Code's permission-mode control above the Composer.
            #expect(accessibleElement(labeled: "Permission mode", in: window) == nil)

            // Select GPT-6-Luna and drive the terminal paste + Enter + confirmation cycle.
            let switchDriver = Task {
                var stepBudget = PollBudget(.seconds(3))
                while await transport.paneSendInputs.count < 1, stepBudget.hasTimeLeft {
                    try await Task.sleep(for: .milliseconds(15))
                    stepBudget.charge()
                }
                await transport.setPaneText(
                    renderPane(history: ["  OpenAI Codex (v0.169.0)"], draft: "/model gpt-6-luna"),
                    paneID: info.paneID)
                stepBudget = PollBudget(.seconds(3))
                while await transport.agentSendKeysParams.count < 1, stepBudget.hasTimeLeft {
                    try await Task.sleep(for: .milliseconds(15))
                    stepBudget.charge()
                }
                await transport.setPaneText(
                    renderPane(
                        history: [
                            "  OpenAI Codex (v0.169.0)",
                            "• Model changed to gpt-6-luna high for this session only",
                        ],
                        footerModel: "GPT-6-Luna high"),
                    paneID: info.paneID)
            }
            defer { switchDriver.cancel() }

            try await HostedMenu.select("GPT-6-Luna", labeled: "Agent settings", in: window)
            budget = PollBudget(.seconds(4))
            while accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue != "GPT-6-Luna · high",
                budget.hasTimeLeft
            {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            try await switchDriver.value
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == "GPT-6-Luna · high")
            let pastes = await transport.paneSendInputs
            #expect(pastes.map(\.text) == ["/model gpt-6-luna"])
            #expect(pastes.map(\.paneID) == [info.paneID])
            let keys = await transport.agentSendKeysParams
            #expect(keys.map(\.keys) == [["enter"]])

            // Effort choices now reflect GPT-6-Luna's supported_reasoning_levels (["low", "high"]).
            let updatedMenu = try await HostedMenu.items(labeled: "Agent settings", in: window)
            #expect(updatedMenu.flatMap { $0 } == ["GPT-6.1-Sol", "GPT-6-Luna", "low", "high"])

            // Switch effort to `low`.
            let effortDriver = Task {
                var stepBudget = PollBudget(.seconds(3))
                while await transport.paneSendInputs.count < 2, stepBudget.hasTimeLeft {
                    try await Task.sleep(for: .milliseconds(15))
                    stepBudget.charge()
                }
                await transport.setPaneText(
                    renderPane(
                        history: [
                            "  OpenAI Codex (v0.169.0)",
                            "• Model changed to gpt-6-luna high for this session only",
                        ],
                        draft: "/model --reasoning=low",
                        footerModel: "GPT-6-Luna high"),
                    paneID: info.paneID)
                stepBudget = PollBudget(.seconds(3))
                while await transport.agentSendKeysParams.count < 2, stepBudget.hasTimeLeft {
                    try await Task.sleep(for: .milliseconds(15))
                    stepBudget.charge()
                }
                await transport.setPaneText(
                    renderPane(
                        history: [
                            "  OpenAI Codex (v0.169.0)",
                            "• Model changed to gpt-6-luna high for this session only",
                            "• Model changed to gpt-6-luna low for this session only",
                        ],
                        footerModel: "GPT-6-Luna low"),
                    paneID: info.paneID)
            }
            defer { effortDriver.cancel() }

            try await HostedMenu.select("low", labeled: "Agent settings", in: window)
            budget = PollBudget(.seconds(4))
            while accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue != "GPT-6-Luna · low",
                budget.hasTimeLeft
            {
                try await Task.sleep(for: .milliseconds(20))
                budget.charge()
            }
            try await effortDriver.value
            #expect(accessibleElement(labeled: "Agent settings", in: window)?.accessibilityValue == "GPT-6-Luna · low")
            #expect(await transport.paneSendInputs.map(\.text) == ["/model gpt-6-luna", "/model --reasoning=low"])
        }
    }
}
