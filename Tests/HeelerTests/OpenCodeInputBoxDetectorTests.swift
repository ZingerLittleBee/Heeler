import Foundation
import Testing

@testable import Heeler

/// OpenCode 2.0.32's input box as captured live at 180 and 62 columns.
/// Only an empty box in a conversation with no turn running takes a
/// message; the home screen, drafts, popups, pickers, shell mode, the
/// subagent panel and a running turn hold it with what the terminal can
/// resolve.
@Suite("OpenCode input box")
struct OpenCodeInputBoxDetectorTests {
    private func detect(_ screen: ANSIScreen) -> InputBoxState {
        InputBoxStateDetector.detect(screen, program: .opencode)
    }

    private func read(_ stem: String) throws -> OpenCodeScreen {
        OpenCodeScreenReader.read(try ScreenFixture.screen(stem))
    }

    private static let home =
        "OpenCode is on its home screen, where a message starts a new conversation. Open this conversation in the terminal first."
    private static let panel = "OpenCode shows its subagent panel instead of the input box. Close it in the terminal first."
    private static let working = "OpenCode is working. Send once it's idle, or steer from the terminal."

    // MARK: Captures

    /// A capture's route and state. A prompt in the box's place has no
    /// route: the Blocked parser reads it before the box is looked for.
    private struct Expected {
        var route: OpenCodeScreen.Route?
        var state: InputBoxState

        init(_ route: OpenCodeScreen.Route?, _ state: InputBoxState) {
            self.route = route
            self.state = state
        }
    }

    /// The first row of the `/` popup, and of the `@` popup.
    private static let agentsCommand = "/agents       Switch agent"
    private static let openCodeSkill =
        "@opencode Use this skill for any question about OpenCode itself, including how OpenCode works, using or configuring it, migrating from V1 to V2, troubleshooting it, de  skill"
    private static let recalledPrompt =
        "Use the task tool with a general subagent to run ls -la in this directory and summarize it, then reply in one line."
    private static let wrappedDraft = """
        Reply with the word kiwi, then name three fruits that
        grow on trees in warm climates, one per line.
        Keep the whole answer short.
        """
    private static let dialog = Expected(nil, .dialog(title: nil))
    private static let empty = Expected(.session, .empty(placeholder: nil))

    /// §5's table: every capture, with its route and state.
    private static let expected: [String: Expected] = [
        "opencode-01-home-empty-180": Expected(.home, .noComposer(home)),
        "opencode-02-session-empty-180": empty,
        "opencode-03-session-draft-180": Expected(.session, .text("A draft line that is not sent")),
        "opencode-04-slash-popup-180": Expected(.session, .overlay(agentsCommand)),
        "opencode-05-slash-space-180": Expected(.session, .text("/")),
        "opencode-06-at-popup-180": Expected(.session, .overlay(openCodeSkill)),
        "opencode-07-shell-mode-180": Expected(.session, .shellMode("")),
        "opencode-08-working-180": Expected(.session, .disabled(working)),
        "opencode-09-armed-180": Expected(.session, .disabled(working)),
        "opencode-10-permission-180": dialog,
        "opencode-11-permission-right1-180": dialog,
        "opencode-12-permission-right2-180": dialog,
        "opencode-13-question-180": dialog,
        "opencode-14-session-picker-180": Expected(.session, .overlay("Sessions for proj")),
        "opencode-15-subagent-panel-180": Expected(.subagentPanel, .noComposer(panel)),
        "opencode-16-child-view-180": Expected(.subagentPanel, .noComposer(panel)),
        "opencode-17-recalled-draft-180": Expected(.session, .text(recalledPrompt)),
        "opencode-18-home-after-new-180": Expected(.home, .noComposer(home)),
        "opencode-19-undo-draft-180": Expected(.session, .text("Reply with exactly: three.")),
        "opencode-20-pasted-lines-180": Expected(.session, .text("[Pasted ~1 lines]")),
        "opencode-21-done-interrupted-180": empty,
        "opencode-22-home-draft-180": Expected(.home, .text("Reply with the word kiwi")),
        "opencode-23-at-space-180": Expected(.session, .text("@")),
        "opencode-24-after-ctrl-u-180": empty,
        "opencode-25-reject-feedback-180": dialog,
        "opencode-26-session-command-draft-180": Expected(.session, .text("/new")),
        "opencode-27-permission-shell-180": dialog,
        "opencode-28-permission-shell-right1-180": dialog,
        "opencode-29-permission-shell-next-180": dialog,
        "opencode-30-home-empty-62": Expected(.home, .noComposer(home)),
        "opencode-31-home-draft-62": Expected(.home, .text("Reply with the word kiwi")),
        "opencode-32-session-empty-62": empty,
        "opencode-33-wrapped-draft-62": Expected(.session, .text(wrappedDraft)),
        "opencode-34-pasted-lines-62": Expected(.session, .text("[Pasted ~3 lines]")),
        "opencode-35-working-62": Expected(.session, .disabled(working)),
        "opencode-36-armed-62": Expected(.session, .disabled(working)),
        "opencode-37-permission-long-62": dialog,
        "opencode-38-question-long-62": dialog,
        "opencode-39-slash-popup-62": Expected(.session, .overlay(agentsCommand)),
        "opencode-40-shell-mode-62": Expected(.session, .shellMode("")),
        "opencode-41-subagent-panel-62": Expected(.subagentPanel, .noComposer(panel)),
        "opencode-42-reject-feedback-62": dialog,
        "opencode-43-queued-dock-62": Expected(.session, .disabled(working)),
    ]

    private func expectItsState(_ stem: String) throws {
        let expected = try #require(Self.expected[stem], "\(stem) has no expected state")
        let screen = try ScreenFixture.screen(stem)
        #expect(detect(screen) == expected.state)
        if let route = expected.route {
            #expect(OpenCodeScreenReader.read(screen).route == route)
        }
    }

    @Test(arguments: ScreenFixture.opencode.filter { $0.hasSuffix("-180") })
    func capturedScreensReadAsTheirState(stem: String) throws {
        try expectItsState(stem)
    }

    /// At 62 columns a draft wraps, the home screen's placeholder is cut
    /// short, and the footer can cut its hint to `esc...rupt`.
    @Test(arguments: ScreenFixture.opencode.filter { $0.hasSuffix("-62") })
    func phoneWidthScreensReadAsTheirState(stem: String) throws {
        try expectItsState(stem)
    }

    // MARK: Routes and states

    /// OpenCode draws a placeholder only on its home screen, in the color
    /// its footer starts with. Without the logo above the box the
    /// placeholder still marks home; the same words in the text color are
    /// a draft.
    @Test func theHomePlaceholderMarksHomeNotAnEmptyBox() throws {
        for stem in ["opencode-01-home-empty-180", "opencode-18-home-after-new-180", "opencode-30-home-empty-62"] {
            let screen = try read(stem)
            #expect(screen.route == .home, "\(stem)")
            #expect(screen.state == .noComposer(Self.home), "\(stem)")
        }

        let words = "Ask anything… \"Fix a TODO in the codebase\""
        let placeholder = OpenCodeScreenReader.read(Self.prompt([Self.muted + words]))
        #expect(placeholder.route == .home)
        #expect(placeholder.state == .noComposer(Self.home))
        let typed = OpenCodeScreenReader.read(Self.prompt([Self.text + words]))
        #expect(typed.route == .session)
        #expect(typed.state == .text(words))
    }

    /// Text in the home screen's box would start a new conversation; it
    /// holds as a draft.
    @Test func aHomeDraftIsText() throws {
        for stem in ["opencode-22-home-draft-180", "opencode-31-home-draft-62"] {
            let screen = try read(stem)
            #expect(screen.route == .home, "\(stem)")
            #expect(screen.state == .text("Reply with the word kiwi"), "\(stem)")
        }
    }

    /// Up recalls an earlier prompt into the box, and `/undo` puts the
    /// undone one back.
    @Test(arguments: ["opencode-17-recalled-draft-180", "opencode-19-undo-draft-180"])
    func aRecalledOrUndoneDraftIsText(stem: String) throws {
        let screen = try read(stem)
        #expect(screen.route == .session)
        #expect(
            screen.state
                == .text(stem == "opencode-17-recalled-draft-180" ? Self.recalledPrompt : "Reply with exactly: three."))
    }

    /// `/new` typed without its popup is text Enter would submit; so are a
    /// `/` or `@` whose popup a typed space closed.
    @Test func aTypedCommandWithoutAPopupIsADraft() throws {
        #expect(detect(try ScreenFixture.screen("opencode-26-session-command-draft-180")) == .text("/new"))
        #expect(detect(try ScreenFixture.screen("opencode-05-slash-space-180")) == .text("/"))
        #expect(detect(try ScreenFixture.screen("opencode-23-at-space-180")) == .text("@"))
    }

    /// OpenCode folds a paste into a `[Pasted ~N lines]` token.
    @Test func pastedLinesAreText() throws {
        #expect(detect(try ScreenFixture.screen("opencode-20-pasted-lines-180")) == .text("[Pasted ~1 lines]"))
        #expect(detect(try ScreenFixture.screen("opencode-34-pasted-lines-62")) == .text("[Pasted ~3 lines]"))
    }

    /// `!` on an empty box turns the agent row to `Shell` and the footer
    /// to `esc exit shell mode`, with the command typed so far in the box.
    @Test func shellModeIsShellMode() throws {
        for stem in ["opencode-07-shell-mode-180", "opencode-40-shell-mode-62"] {
            #expect(detect(try ScreenFixture.screen(stem)) == .shellMode(""), "\(stem)")
        }

        let footer = Self.footer(Self.muted + "~/project:main  " + Self.text + "esc " + Self.muted + "exit shell mode")
        let label = Self.shellAccent + "Shell"
        let typed = Self.prompt([Self.text + "ls -la"], label: label, accent: Self.shellAccent, footer: footer)
        #expect(detect(typed) == .shellMode("ls -la"))
        // On the home screen, shell mode has a placeholder of its own.
        let home = Self.prompt(
            [Self.muted + "Run a command… \"git diff\""], label: label, accent: Self.shellAccent, footer: footer)
        #expect(OpenCodeScreenReader.read(home).route == .home)
        #expect(detect(home) == .shellMode(""))
    }

    /// The session picker is a modal titled with the key that closes it;
    /// `/` and `@` popups sit on the box with a bar at both edges.
    @Test(arguments: [
        "opencode-04-slash-popup-180", "opencode-06-at-popup-180", "opencode-14-session-picker-180",
        "opencode-39-slash-popup-62",
    ])
    func popupsAndModalsAreOverlays(stem: String) throws {
        let title =
            switch stem {
            case "opencode-06-at-popup-180": Self.openCodeSkill
            case "opencode-14-session-picker-180": "Sessions for proj"
            default: Self.agentsCommand
            }
        let screen = try read(stem)
        #expect(screen.route == .session)
        #expect(screen.overlayTitle == title)
        #expect(screen.state == .overlay(title))
        #expect(detect(try ScreenFixture.screen(stem)) == .overlay(title))
    }

    /// Down on an empty box opens the panel, and a subagent's view keeps
    /// it under the transcript; neither has the conversation's box.
    @Test(arguments: [
        "opencode-15-subagent-panel-180", "opencode-16-child-view-180", "opencode-41-subagent-panel-62",
    ])
    func theSubagentPanelHasNoComposer(stem: String) throws {
        let screen = try read(stem)
        #expect(screen.route == .subagentPanel)
        #expect(screen.state == .noComposer(Self.panel))
        #expect(detect(try ScreenFixture.screen(stem)) == .noComposer(Self.panel))
    }

    /// Enter in an empty box while a turn runs would steer it, and a
    /// prompt that shows before herdr's Enter would take that Enter as its
    /// answer (decision 1). herdr's status can lag the screen, so the hold
    /// comes from the footer.
    @Test(arguments: [
        "opencode-08-working-180", "opencode-09-armed-180", "opencode-35-working-62", "opencode-36-armed-62",
    ])
    func aWorkingSessionHoldsSends(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)
        #expect(detect(screen) == .disabled(Self.working))
        for activity in [ChatAgentActivity.working, .idle, .unknown] {
            #expect(PreSendGate.check(screen, program: .opencode, activity: activity) == .hold(.disabled(Self.working)))
        }
    }

    /// No edge row, no box; nor does an edge without the box's rows above
    /// it make one.
    @Test func aScreenWithoutTheBoxEdgeIsUnknown() {
        let transcript = ScreenFixture.synthetic(["   I'll check the tests.", "", "   Done.", ""])
        #expect(detect(transcript) == .unknown("OpenCode's input box is not on screen."))
        #expect(OpenCodeScreenReader.read(transcript).route == .unknown)

        let edgeOnly = ScreenFixture.synthetic(["   Done.", "", Self.edge(), Self.idleFooter, ""])
        #expect(detect(edgeOnly) == .unknown("OpenCode's input box is not recognized."))
        #expect(OpenCodeScreenReader.read(edgeOnly).route == .unknown)
    }

    /// The footer's progress bar and `esc interrupt` say a turn runs, and
    /// `esc again to interrupt` that one Esc armed the interrupt. At 62
    /// columns the hint can be cut to `esc...rupt`, and then the bar says it
    /// alone.
    @Test func theFooterSaysWhetherATurnRunsAndEscIsArmed() throws {
        let captures: [(stem: String, running: Bool, armed: Bool)] = [
            ("opencode-02-session-empty-180", false, false), ("opencode-07-shell-mode-180", false, false),
            ("opencode-08-working-180", true, false), ("opencode-09-armed-180", true, true),
            ("opencode-21-done-interrupted-180", false, false), ("opencode-32-session-empty-62", false, false),
            ("opencode-35-working-62", true, false), ("opencode-36-armed-62", true, true),
            ("opencode-43-queued-dock-62", true, false),
        ]
        for capture in captures {
            let screen = try read(capture.stem)
            #expect(screen.isRunning == capture.running, "\(capture.stem)")
            #expect(screen.isArmed == capture.armed, "\(capture.stem)")
        }

        // With animations off, `[⋯]` stands in for the bar.
        let still = OpenCodeScreenReader.read(
            Self.prompt(footer: Self.footer(Self.text + "[⋯] esc...rupt  " + Self.muted + "ctrl+p commands")))
        #expect(still.isRunning)
        #expect(!still.isArmed)
        #expect(still.state == .disabled(Self.working))
    }

    /// The box is found by its text and layout, so a theme Heeler doesn't
    /// know, or no color at all, reads the same.
    @Test func colourlessRowsStillFindTheBox() throws {
        for stem in ScreenFixture.opencode {
            let text = try ScreenFixture.text(stem)
            let colourless = text.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            #expect(!colourless.contains("\u{1B}"), "\(stem)")
            #expect(
                OpenCodeScreenReader.read(ANSIScreenDecoder.decode(colourless))
                    == OpenCodeScreenReader.read(ANSIScreenDecoder.decode(text)), "\(stem)")
        }
    }

    // MARK: Helpers

    /// OpenCode's default dark theme, as the captures draw it.
    private static let screenFill = SGR.bg(10, 10, 10)
    private static let boxFill = SGR.bg(30, 30, 30)
    private static let buildAccent = SGR.fg(92, 156, 245)
    private static let shellAccent = SGR.fg(250, 178, 131)
    private static let text = SGR.fg(238, 238, 238)
    private static let muted = SGR.fg(128, 128, 128)
    private static let columns = 62

    private static let buildLabel = buildAccent + "Build " + muted + "· " + text + "GPT-6 Astra"
    private static let idleFooter = footer(muted + "~/project:main  " + text + "ctrl+p " + muted + "commands")

    /// One row of the box behind its bar: `content` two cells in, padded
    /// to the box's right edge. `content` sets only foregrounds.
    private static func boxRow(_ content: String = "", accent: String = buildAccent) -> String {
        let inner = content.isEmpty ? "" : "  " + content
        let padding = String(repeating: " ", count: columns - 5 - width(of: inner))
        return "\(screenFill)  \(accent)┃\(boxFill)\(inner)\(boxFill)\(padding)\(screenFill)  \(SGR.reset)"
    }

    /// The row that closes the box.
    private static func edge(accent: String = buildAccent) -> String {
        let halfBlocks = String(repeating: "▀", count: columns - 5)
        return "\(screenFill)  \(accent)╹\(SGR.fg(30, 30, 30))\(halfBlocks)\(SGR.fg(255, 255, 255))  \(SGR.reset)"
    }

    private static func footer(_ content: String) -> String {
        "\(screenFill)  \(content)\(SGR.reset)"
    }

    /// A conversation at 62 columns: a reply, then the box with `input`
    /// rows above the agent row `label`, its edge, and `footer`.
    private static func prompt(
        _ input: [String] = [""], label: String = buildLabel, accent: String = buildAccent,
        footer: String = idleFooter
    ) -> ANSIScreen {
        let box = [boxRow(accent: accent)] + input.map { boxRow($0, accent: accent) } + [
            boxRow(accent: accent), boxRow(label, accent: accent),
        ]
        return ScreenFixture.synthetic(["   Done.", ""] + box + [edge(accent: accent), footer, ""])
    }

    private static func width(of styled: String) -> Int {
        TerminalCellWidth.width(
            of: styled.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression))
    }
}
