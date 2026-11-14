import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Heeler

@Suite("Antigravity CLI model catalog and session settings")
struct AgyModelSessionTests {
    private static let sampleModelsOutput = """
        \r⠋ Loading models...\rgemini-4-carbon-medium         Gemini 4 Carbon (Medium)
        gemini-4-carbon-high           Gemini 4 Carbon (High)
        gemini-4-carbon-low            Gemini 4 Carbon (Low)
        gemini-4-hydrogen-high         Gemini 4 Hydrogen (High)
        gemini-4-hydrogen-xhigh        Gemini 4 Hydrogen (XHigh)
        gemini-4-hydrogen-medium       Gemini 4 Hydrogen (Medium)
        gemini-4-hydrogen-low          Gemini 4 Hydrogen (Low)
        gemini-pro-orchestrator        Orchestrator (Carbon)
        gemini-3.8-flash-high          Gemini 3.8 Flash (High)
        gemini-3.8-flash-low           Gemini 3.8 Flash (Low)
        claude-opus-5-5-low            Claude Opus 5.5 (Low)
        claude-opus-5-5-medium         Claude Opus 5.5 (Medium)
        claude-opus-5-5-high           Claude Opus 5.5 (High)
        gpt-oss-120b-medium            GPT-OSS 120B (Medium)
        """

    @Test("agy models groups multi-effort families and keeps single-variant models intact")
    func parsesAndGroupsModelCatalog() throws {
        let choices = AgyModelCatalog.parse(Data(Self.sampleModelsOutput.utf8))
        #expect(choices.map(\.title) == [
            "Gemini 4 Carbon",
            "Gemini 4 Hydrogen",
            "Orchestrator (Carbon)",
            "Gemini 3.8 Flash",
            "Claude Opus 5.5",
            "GPT-OSS 120B (Medium)",
        ])

        let carbon = try #require(choices.first { $0.id == "gemini-4-carbon" })
        #expect(carbon.efforts == ["low", "medium", "high"])
        #expect(carbon.defaultSlug == "gemini-4-carbon-medium")
        #expect(carbon.slug(preferringEffort: "high") == "gemini-4-carbon-high")
        #expect(carbon.slug(preferringEffort: "xhigh") == "gemini-4-carbon-medium")
        #expect(carbon.matches(model: "Gemini 4 Carbon"))
        #expect(carbon.matches(model: "gemini-4-carbon-high"))

        let hydrogen = try #require(choices.first { $0.id == "gemini-4-hydrogen" })
        #expect(hydrogen.efforts == ["low", "medium", "high", "xhigh"])
        #expect(hydrogen.slug(preferringEffort: "xhigh") == "gemini-4-hydrogen-xhigh")

        let orchestrator = try #require(choices.first { $0.id == "gemini-pro-orchestrator" })
        #expect(orchestrator.efforts.isEmpty)
        #expect(orchestrator.slug(preferringEffort: "high") == "gemini-pro-orchestrator")
        #expect(orchestrator.matches(model: "Orchestrator (Carbon)"))

        let gptOss = try #require(choices.first { $0.id == "gpt-oss-120b-medium" })
        #expect(gptOss.efforts.isEmpty)
        #expect(gptOss.matches(model: "GPT-OSS 120B (Medium)"))
        // A transcript <USER_SETTINGS_CHANGE> parsed without catalog context still highlights it.
        #expect(gptOss.matches(model: "GPT-OSS 120B"))

        #expect(AgyModelCatalog.resolveDisplayLabel("GPT-OSS 120B (Medium)", in: choices)
            == (model: "GPT-OSS 120B (Medium)", effort: nil))
        #expect(AgyModelCatalog.resolveDisplayLabel("Gemini 3.8 Flash (Low)", in: choices)
            == (model: "Gemini 3.8 Flash", effort: "low"))
        #expect(AgyModelCatalog.resolveDisplayLabel("Orchestrator (Carbon)", in: choices)
            == (model: "Orchestrator (Carbon)", effort: nil))
        #expect(AgyModelCatalog.resolveModelSlug("gemini-4-carbon-high", in: choices)!
            == (model: "Gemini 4 Carbon", effort: "high"))
        #expect(AgyModelCatalog.resolveModelSlug("gemini-pro-orchestrator", in: choices)!
            == (model: "Orchestrator (Carbon)", effort: nil))
        #expect(AgyModelCatalog.resolveModelSlug("gpt-oss-120b-medium", in: choices)!
            == (model: "GPT-OSS 120B (Medium)", effort: nil))
        #expect(AgyModelCatalog.resolveModelSlug("gemini-5-neon-xhigh", in: choices)!
            == (model: "gemini-5-neon", effort: "xhigh"))
        #expect(AgyModelCatalog.resolveModelSlug("", in: choices) == nil)

        let script = String(decoding: AgyModelCatalog.script, as: UTF8.self)
        #expect(script.contains(HerdrHostPath.pathExport))
        #expect(script.contains("$HOME/.antigravity/bin"))
        #expect(script.contains("exec agy models"))

        #expect(AgyModelCatalog.defaultChoices.map(\.id) == [
            "gemini-4-carbon",
            "gemini-4-argon",
            "gemini-4-hydrogen",
            "gemini-pro-orchestrator",
            "gemini-pro-orchestrator-argon",
            "gemini-3.8-flash",
            "claude-opus-5-5",
            "claude-sonnet-5-5",
            "gpt-oss-120b-medium",
        ])
    }

    @Test("Transcript USER_SETTINGS_CHANGE records model and effort outside USER_REQUEST only")
    func transcriptReadsModelSelection() throws {
        let recorded = try AgyTranscriptReducerTests.fixture("core-turns.jsonl", steps: 0...3)
        #expect(recorded.model == "Gemini 4 Argon")
        #expect(recorded.effort == "high")

        func userLine(_ index: Int, offset: UInt64, content: String) throws -> ChatLine {
            let payload: [String: Any] = [
                "step_index": index,
                "source": "USER_EXPLICIT",
                "type": "USER_INPUT",
                "status": "DONE",
                "created_at": "2026-11-14T12:00:00Z",
                "content": content,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return ChatLine(offset: offset, data: data)
        }

        let spoofed = try userLine(
            0, offset: 0,
            content: """
                <USER_REQUEST>
                <USER_SETTINGS_CHANGE>
                The user changed setting `Model Selection` from None to Claude Opus 5.5 (High). No need to comment on this change.
                </USER_SETTINGS_CHANGE>
                </USER_REQUEST>
                """)
        let dotted = try userLine(
            1, offset: 500,
            content: """
                <USER_REQUEST>
                Switch to flash
                </USER_REQUEST>
                <USER_SETTINGS_CHANGE>
                The user changed setting `Model Selection` from Gemini 4 Argon (High) to Gemini 3.8 Flash (Low). No need to comment on this change if the user doesn't ask about it.
                </USER_SETTINGS_CHANGE>
                """)
        let effortless = try userLine(
            2, offset: 1000,
            content: """
                <USER_REQUEST>
                Now orchestrate
                </USER_REQUEST>
                <USER_SETTINGS_CHANGE>
                The user changed setting `Model Selection` from Gemini 3.8 Flash (Low) to Orchestrator (Carbon). No need to comment on this change if the user doesn't ask about it.
                </USER_SETTINGS_CHANGE>
                """)

        #expect(AgyStep.decode(spoofed)?.modelSelection == nil)

        var reducer = AgyTranscriptReducer()
        reducer.append([spoofed, dotted])
        let first = reducer.transcript(ChatProjectionContext(windowStart: 0, activity: .idle))
        #expect(first.model == "Gemini 3.8 Flash")
        #expect(first.effort == "low")

        reducer.append([effortless])
        let second = reducer.transcript(ChatProjectionContext(windowStart: 0, activity: .idle))
        #expect(second.model == "Orchestrator (Carbon)")
        #expect(second.effort == nil)
    }

    @Test("Tail-loaded transcripts resolve active model and effort from PLANNER_RESPONSE slugs")
    func transcriptReadsPlannerResponseModelWhenInitialSettingIsAboveWindow() throws {
        func plannerLine(_ index: Int, offset: UInt64, model: String, text: String) throws -> ChatLine {
            let payload: [String: Any] = [
                "step_index": index,
                "source": "MODEL",
                "type": "PLANNER_RESPONSE",
                "status": "DONE",
                "created_at": "2026-11-14T13:45:00Z",
                "model": model,
                "content": text,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return ChatLine(offset: offset, data: data)
        }
        func userLine(_ index: Int, offset: UInt64, content: String) throws -> ChatLine {
            let payload: [String: Any] = [
                "step_index": index,
                "source": "USER_EXPLICIT",
                "type": "USER_INPUT",
                "status": "DONE",
                "created_at": "2026-11-14T13:46:00Z",
                "content": content,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload)
            return ChatLine(offset: offset, data: data)
        }

        var reducer = AgyTranscriptReducer()
        reducer.append([
            try userLine(272, offset: 1_400_000, content: "<USER_REQUEST>\nSummarize changes\n</USER_REQUEST>"),
            try plannerLine(273, offset: 1_401_000, model: "gemini-4-carbon-high", text: "Summary"),
        ])
        let tailOnly = reducer.transcript(ChatProjectionContext(windowStart: 1_380_000, activity: .idle))
        #expect(tailOnly.needsOlderHistory)
        #expect(tailOnly.model == "Gemini 4 Carbon")
        #expect(tailOnly.effort == "high")

        // A later USER_SETTINGS_CHANGE before the next reply supersedes the earlier PLANNER_RESPONSE.
        reducer.append([
            try userLine(
                274, offset: 1_402_000,
                content: """
                    <USER_REQUEST>
                    Use GPT-OSS
                    </USER_REQUEST>
                    <USER_SETTINGS_CHANGE>
                    The user changed setting `Model Selection` from Gemini 4 Carbon (High) to GPT-OSS 120B (Medium). No need to comment on this change.
                    </USER_SETTINGS_CHANGE>
                    """),
        ])
        let switched = reducer.transcript(ChatProjectionContext(windowStart: 1_380_000, activity: .working))
        #expect(switched.model == "GPT-OSS 120B (Medium)")
        #expect(switched.effort == nil)
    }

    @Test(arguments: [
        ("agy-02-idle-empty-120x40", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-76-mode-cycle-1-120x40", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-76-mode-cycle-2-120x40", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-76-mode-cycle-3-120x40", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-123-nocolor-mode-cycle-accept-edits-92x47", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-169-plain-working-background-task-120x40", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "medium")),
        ("agy-183-tasks-panel-running-62x46", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "medium")),
        ("agy-91-bang-typed-62x41", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-84-footer-modes-40x30-40x30", nil),
        ("agy-119-nocolor-bash-mode-empty-45x45", nil),
        ("agy-122-nocolor-accept-edits-hint-cut-45x45", nil),
        ("agy-88-exit-with-conversation-120x40", nil),
        ("agy-151-nocolor-exit-with-conversation-92x47", nil),
    ] as [(String, AgyScreen.FooterModel?)])
    func footerReadsModelAcrossPalettesAndWidths(stem: String, expected: AgyScreen.FooterModel?) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(AgyScreen(screen).footerModel == expected)
    }

    @Test("Footer parses single-variant models without an effort suffix")
    func footerReadsEffortlessModel() {
        let rule = String(repeating: "─", count: 80)
        let screen = ScreenFixture.synthetic([
            rule, "> ", rule, "? for shortcuts                                          Orchestrator (Carbon)",
        ])
        #expect(AgyScreen(screen).footerModel == AgyScreen.FooterModel(model: "Orchestrator (Carbon)", effort: nil))
    }

    @Test(arguments: [
        ("agy-122-nocolor-accept-edits-hint-cut-45x45", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-119-nocolor-bash-mode-empty-45x45", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-90-first-screen-welcome-40x30", AgyScreen.FooterModel(model: "Gemini 4 Argon", effort: "high")),
        ("agy-89-warning-notice-bad-model-120x40", nil),
        ("agy-100-ask-question-multiselect-62x41", nil),
        ("agy-88-exit-with-conversation-120x40", nil),
    ] as [(String, AgyScreen.FooterModel?)])
    func welcomeBannerReadsModelBeforeAnyOutputEvenWhenNarrowFooterDropsIt(
        stem: String, expected: AgyScreen.FooterModel?
    ) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(AgyScreen(screen).welcomeModel == expected)
    }

    @Test("CommandOutcome confirms /model and /effort answers, including full-screen scroll and warnings")
    func commandOutcome() throws {
        let rule = String(repeating: "─", count: 80)
        func agyBoxScreen(above: [String], draft: String = "", footer: String = "? for shortcuts                                        Gemini 4 Carbon · medium") -> ANSIScreen {
            let prompt = draft.isEmpty ? "> " : "> \(draft)"
            return ScreenFixture.synthetic(above + [rule, prompt, rule, footer])
        }

        let before = AgyScreen.CommandOutcome(
            of: .model,
            on: agyBoxScreen(above: ["> /model", "  ⎿  Model set to Gemini 4 Argon (High)"]))
        #expect(before.echoes == 1)

        // Draft still in the input box has not been submitted yet.
        let typing = AgyScreen.CommandOutcome(
            of: .model,
            on: agyBoxScreen(above: ["> /model", "  ⎿  Model set to Gemini 4 Argon (High)"], draft: "/model gemini-4-carbon-medium"))
        #expect(typing.answered(since: before) == nil)

        // Full screen scrolled the older `> /model` off the top while adding the new one.
        let scrolled = AgyScreen.CommandOutcome(
            of: .model,
            on: agyBoxScreen(above: ["  ⎿  Model set to Gemini 4 Argon (High)", "> /model", "  ⎿  Model set to Gemini 4 Carbon (Medium)"]))
        #expect(scrolled.echoes == 1)
        #expect(scrolled.answered(since: before) == true)
        #expect(scrolled.value == "Gemini 4 Carbon (Medium)")

        let already = AgyScreen.CommandOutcome(
            of: .model,
            on: agyBoxScreen(above: ["> /model", "  ⎿  Model set to Gemini 4 Argon (High)", "> /model", "  ⎿  Model already set to Gemini 4 Carbon (High)"]))
        #expect(already.answered(since: before) == true)
        #expect(already.value == "Gemini 4 Carbon (High)")

        let badModel = AgyScreen.CommandOutcome(
            of: .model,
            on: try ScreenFixture.screen("agy-89-warning-notice-bad-model-120x40"))
        let emptyBefore = AgyScreen.CommandOutcome(of: .model, on: agyBoxScreen(above: []))
        #expect(badModel.answered(since: emptyBefore) == false)

        let effortBefore = AgyScreen.CommandOutcome(of: .effort, on: agyBoxScreen(above: []))
        let effortSet = AgyScreen.CommandOutcome(
            of: .effort,
            on: agyBoxScreen(above: ["> /effort", "  ⎿  Effort set to low"]))
        #expect(effortSet.answered(since: effortBefore) == true)
        #expect(effortSet.value == "low")

        let effortRefused = AgyScreen.CommandOutcome(
            of: .effort,
            on: agyBoxScreen(above: ["> /effort", "  ⎿  Effort isn't adjustable for Orchestrator (Carbon)."]))
        #expect(effortRefused.answered(since: effortBefore) == false)
    }

    @Test(.serialized)
    @MainActor func headerOffersModelMenuForAgyWithoutShowingPermissionChrome() async throws {
        let agent = Agent(
            terminalID: "term_w1:p1", kind: "agy", title: "Refactor auth flow", status: .idle,
            workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p1", cwd: "/Users/bee/workspace/heeler",
            revision: 1, name: nil)
        let consoleAgent = ConsoleAgent(
            hostID: Host.fixture(name: "studio").id, hostName: "studio", agent: agent,
            workspaceLabel: nil, repositoryCheckout: nil, hostUsername: "bee")
        let settings = AgentSessionSettings(model: "Gemini 4 Carbon", permissionMode: nil, effort: "high")
        let controls = AgentSessionControls(
            isEnabled: true,
            modelChoices: [("gemini-4-carbon", "Gemini 4 Carbon"), ("gemini-pro-orchestrator", "Orchestrator (Carbon)")],
            effortChoices: ["low", "medium", "high"],
            modelMatches: { model, id in model == "Gemini 4 Carbon" && id == "gemini-4-carbon" },
            setPermissionMode: nil,
            setModel: { _ in },
            setEffort: { _ in })

        let root = VStack {
            AgentDetailHeader(
                palette: .system, isExpanded: .constant(true), onBack: {},
                title: AgentDetailHeaderTitle(consoleAgent),
                sessionSettings: settings,
                sessionControls: controls)
            AgentDetailStatusChrome(
                status: .idle, hostTelemetry: nil, changes: nil,
                session: settings, sessionControls: controls,
                chromeColorScheme: .dark)
        }
        .padding(.horizontal, 12)

        let controller = UIHostingController(rootView: root)
        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 240), rootViewController: controller
        ) { window in
            try await Task.sleep(for: .milliseconds(300))
            let elements = accessibleElements(in: window)
            let identifiers = Set(elements.compactMap { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier })
            let labels = elements.compactMap(\.accessibilityLabel).joined(separator: " | ")
            let values = elements.compactMap(\.accessibilityValue).joined(separator: " | ")
            #expect(identifiers.contains("agent-header-model") || labels.contains("Agent settings"))
            #expect(!identifiers.contains("agent-status-permission"))
            #expect(!labels.contains("Permission mode"))
            #expect(values.contains("Gemini 4 Carbon · high"))
        }
    }

    @Test(.serialized)
    @MainActor func headerShowsModelPlaceholderWhenSwitchableSessionHasNoReportedModelYet() async throws {
        let agent = Agent(
            terminalID: "term_w44:p1", kind: "agy", title: "~/D/w/H/worktree-brave-meadow-af28", status: .idle,
            workspaceID: "w44", tabID: "w44:t1", paneID: "w44:p1",
            cwd: "/Users/bee/Documents/worktree/Heeler/worktree-brave-meadow-af28",
            revision: 1, name: "agy-3")
        let consoleAgent = ConsoleAgent(
            hostID: Host.fixture(name: "studio").id, hostName: "studio", agent: agent,
            workspaceLabel: nil, repositoryCheckout: nil, hostUsername: "bee")
        let settings = AgentSessionSettings(model: nil, permissionMode: nil, effort: nil)
        let controls = AgentSessionControls(
            isEnabled: true,
            modelChoices: [("gemini-4-carbon", "Gemini 4 Carbon"), ("gemini-pro-orchestrator", "Orchestrator (Carbon)")],
            effortChoices: [],
            modelMatches: { _, _ in false },
            setPermissionMode: nil,
            setModel: { _ in },
            setEffort: { _ in })

        var pickedModel: String?
        let interactiveControls = AgentSessionControls(
            isEnabled: controls.isEnabled,
            modelChoices: controls.modelChoices,
            effortChoices: controls.effortChoices,
            modelMatches: controls.modelMatches,
            setPermissionMode: nil,
            setModel: { pickedModel = $0 },
            setEffort: { _ in })

        let controller = UIHostingController(rootView: AgentDetailHeader(
            palette: .system, isExpanded: .constant(true), onBack: {},
            title: AgentDetailHeaderTitle(consoleAgent),
            sessionSettings: settings,
            sessionControls: interactiveControls)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity, alignment: .top))

        try await withTestWindow(
            frame: CGRect(x: 0, y: 0, width: 402, height: 240), rootViewController: controller
        ) { window in
            try await Task.sleep(for: .milliseconds(300))
            let settingsControl = try #require(accessibleElement(labeled: "Agent settings", in: window))
            #expect(settingsControl.accessibilityValue == "Model")
            try await HostedMenu.select("Gemini 4 Carbon", labeled: "Agent settings", in: window)
            #expect(pickedModel == "gemini-4-carbon")
        }
    }
}
