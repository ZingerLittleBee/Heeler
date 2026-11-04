import Foundation
import Testing

@testable import Heeler

/// Grok Build's input box, read from Grok Build 1.0.62 captures and from
/// synthetic screens `GrokScreenBuilder` lays out the way Grok does, for
/// states and widths no capture shows yet.
@Suite("Grok Build input box")
struct GrokInputBoxDetectorTests {
    private static let unfocused =
        "Grok Build's input box doesn't have focus. Go back to it in the terminal, then send again."
    private static let waiting =
        "Grok Build is waiting on a subagent or a background task, and a message now would cancel that turn."

    /// A capture by stem, or a synthetic screen by its label.
    private static func screen(_ name: String) throws -> ANSIScreen {
        if let screen = synthetic(name) { return screen }
        return try ScreenFixture.screen(name)
    }

    /// grok-03: a command running.
    private static func working(columns: Int) -> GrokScreenBuilder {
        GrokScreenBuilder(
            columns: columns,
            status: .init(
                label: "Sleep 45 seconds then echo done…", phase: "1.1s", turn: "3.2s ⇣25.5k",
                buttons: " [↓][stop]"),
            hints: ["Shift+Tab:mode", "Ctrl+c:cancel", "Ctrl+b:send to bg", "Ctrl+.:shortcuts"])
    }

    /// grok-05: a command running with a message queued.
    private static func queued(columns: Int) -> GrokScreenBuilder {
        GrokScreenBuilder(
            columns: columns,
            status: .init(
                label: "Sleep 40 seconds then echo two…", phase: "15s", turn: "18s ⇣25.8k",
                buttons: " [↓][stop]"),
            dock: ["   ▾ Queued 1", "     #1 After that, reply with the word three."],
            hints: [
                "Enter:send now", "Shift+Tab:mode", "Ctrl+c:cancel", "Ctrl+b:send to bg", "Ctrl+;:queue",
                "Ctrl+.:shortcuts",
            ])
    }

    /// grok-26: the turn waits for a subagent the dock lists.
    private static func subagentWait(columns: Int, label: String = "Waiting for subagent…") -> GrokScreenBuilder {
        GrokScreenBuilder(
            columns: columns, status: .init(label: label),
            dock: ["   ▾ Subagents 1", "   ⋅ Subagent List workspace files · Waiting for response…"],
            hints: ["Shift+Tab:mode", "Ctrl+c:cancel", "Ctrl+.:shortcuts"])
    }

    /// A wait with no dock: the dock is off, or shows nothing.
    private static func wait(_ label: String, columns: Int = 120, queued: String? = nil) -> GrokScreenBuilder {
        GrokScreenBuilder(
            columns: columns, status: .init(label: label, queued: queued),
            hints: ["Shift+Tab:mode", "Ctrl+c:cancel", "Ctrl+.:shortcuts"])
    }

    private static func synthetic(_ name: String) -> ANSIScreen? {
        switch name {
        case "working at 62 columns (synthetic)": working(columns: 62).screen
        case "working at 40 columns (synthetic)": working(columns: 40).screen
        case "queued at 62 columns (synthetic)": queued(columns: 62).screen
        case "queued at 40 columns (synthetic)": queued(columns: 40).screen
        case "subagent wait at 120 columns (synthetic)": subagentWait(columns: 120).screen
        case "subagent wait at 62 columns (synthetic)": subagentWait(columns: 62).screen
        case "subagent wait at 40 columns (synthetic)": subagentWait(columns: 40).screen
        case "two subagents at 40 columns (synthetic)":
            subagentWait(columns: 40, label: "Waiting for 2 subagents…").screen
        case "Waiting for 2 subagents… (synthetic)": wait("Waiting for 2 subagents…").screen
        case "Waiting on task output… (synthetic)": wait("Waiting on task output…").screen
        case "Waiting on tasks… (synthetic)": wait("Waiting on tasks…").screen
        case "Sleeping… (synthetic)": wait("Sleeping…").screen
        case "a task's subject with Enter to send now (synthetic)":
            wait("Build the docs…", queued: " · 1 queued, Enter to send now").screen
        case "a parked wait (synthetic)":
            GrokScreenBuilder(cue: "waiting · send a message to interrupt").screen
        case "a parked wait with background work at 40 columns (synthetic)":
            GrokScreenBuilder(columns: 40, cue: "1 command still running · send a message to interrupt").screen
        case "a parked wait with a queue (synthetic)":
            GrokScreenBuilder(cue: "1 command still running · 1 queued, Enter to send now").screen
        case "a model wait at 40 columns (synthetic)": wait("Waiting for response…", columns: 40).screen
        case "a prompt not yet accepted (synthetic)": wait("Waiting for the agent to accept the prompt…").screen
        case "background work while idle (synthetic)": GrokScreenBuilder(cue: "1 command still running").screen
        default: nil
        }
    }

    @Test(arguments: [
        "grok-01-idle-empty", "grok-03-working", "grok-05-queued", "grok-20-welcome", "grok-27-compacting",
        "grok-28-welcome-62", "grok-29-welcome-40", "grok-30-idle-62x20", "grok-32-working-62x20",
        "working at 62 columns (synthetic)", "working at 40 columns (synthetic)", "queued at 62 columns (synthetic)",
        "queued at 40 columns (synthetic)",
    ])
    func readsAFocusedEmptyComposer(stem: String) throws {
        #expect(GrokInputBoxDetector.detect(try Self.screen(stem)) == .empty(placeholder: nil))
    }

    @Test func ghostTextIsNotADraft() {
        let builder = GrokScreenBuilder(
            ghost: "Run the tests again", hints: ["Tab/→:accept suggestion", "Shift+Tab:mode", "Ctrl+.:shortcuts"])
        let composer = GrokScreen(builder.screen).composer

        #expect(composer?.draft == "")
        #expect(composer?.ghost == "Run the tests again")
        #expect(GrokInputBoxDetector.detect(builder.screen) == .empty(placeholder: nil))
        // At 40 columns the pinned suggestion hint stays and Shift+Tab:mode
        // is cut.
        var narrow = builder
        narrow.columns = 40
        #expect(GrokScreen(narrow.screen).footer == "Tab/→:accept suggestion  │")
        #expect(GrokInputBoxDetector.detect(narrow.screen) == .empty(placeholder: nil))
    }

    @Test func typedTextBeforeAGhostIsTheDraft() {
        let screen = GrokScreenBuilder(
            typed: "Run the", ghost: " tests again",
            hints: ["Enter:send", "Shift+Enter/Opt+Enter:newline", "Tab/→:accept suggestion", "Shift+Tab:mode"]
        ).screen

        #expect(GrokScreen(screen).composer?.ghost == "tests again")
        #expect(GrokInputBoxDetector.detect(screen) == .text("Run the"))
    }

    @Test(arguments: ["grok-02-idle-draft", "grok-04-working-draft", "grok-24-restored-draft"])
    func readsADraft(stem: String) throws {
        let drafts = [
            "grok-02-idle-draft": "hello draft", "grok-04-working-draft": "draft while working",
            "grok-24-restored-draft": "Reply with the word kiwi.",
        ]

        let draft = try #require(drafts[stem])

        #expect(GrokInputBoxDetector.detect(try ScreenFixture.screen(stem)) == .text(draft))
    }

    @Test func aDraftOnSeveralRowsKeepsItsLines() {
        let screen = GrokScreenBuilder(typed: "first line\nsecond line").screen

        #expect(GrokInputBoxDetector.detect(screen) == .text("first line\nsecond line"))
    }

    /// The queue pane, the dock, Tasks, the scrollback and a subagent's
    /// child surface. Without prompt focus Grok draws its placeholder in
    /// the empty box. 1.0.62's guide says the child surface hides the
    /// composer, which reads as no box at all.
    @Test(arguments: [
        "x:delete row  │  e:edit  │  J/K:reorder  │  y:copy  │  Ctrl+Enter:send now  │  Ctrl+c:cancel",
        "j/k:navigate  │  h:show done  │  Tab:prompt  │  Ctrl+c:cancel",
        "Enter:view  │  y:copy output  │  x:kill  │  h:show done",
        "Space:prompt  │  Ctrl+.:shortcuts",
        "q/Esc:back  │  Ctrl+c:cancel  │  Ctrl+.:shortcuts",
    ])
    func anUnfocusedPromptIsNotEmpty(row: String) {
        let screen = GrokScreenBuilder(placeholder: "Build anything", footer: row).screen

        #expect(GrokScreen(screen).composer?.draft == "")
        #expect(GrokInputBoxDetector.detect(screen) == .disabled(Self.unfocused))
    }

    /// At 20 rows or fewer, as at the phone's 62×20 grid with the keyboard
    /// up, Grok forces compact mode, whose footer is `Ctrl+.:shortcuts`
    /// whatever has focus. With the scrollback focused the empty box shows
    /// the placeholder, idle or working.
    @Test(arguments: ["grok-31-scrollback-62x20", "grok-33-working-scrollback-62x20"])
    func readsACompactScreenWithoutPromptFocus(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)

        #expect(GrokScreen(screen).composer?.draft == "")
        #expect(GrokInputBoxDetector.detect(screen) == .disabled(Self.unfocused))
    }

    @Test func thePlaceholderTypedWithFocusIsADraft() {
        let screen = GrokScreenBuilder(typed: "Build anything").screen

        #expect(GrokInputBoxDetector.detect(screen) == .text("Build anything"))
    }

    @Test func bashModeIsShellMode() {
        let command = GrokScreenBuilder(glyph: "!", typed: "ls -la", bottomLabel: "Run shell command").screen
        let empty = GrokScreenBuilder(glyph: "!", bottomLabel: "Run shell command").screen

        #expect(GrokInputBoxDetector.detect(command) == .shellMode("ls -la"))
        #expect(GrokInputBoxDetector.detect(empty) == .shellMode(""))
    }

    @Test func rememberModeHolds() {
        let screen = GrokScreenBuilder(glyph: "#", typed: "Prefer tabs", bottomLabel: "Save memory note").screen

        #expect(
            GrokInputBoxDetector.detect(screen)
                == .disabled(
                    "Grok Build's input box is in remember mode, where a message is saved as a memory. Leave it in the terminal first."
                ))
    }

    @Test func theDashboardHasNoComposer() throws {
        #expect(
            GrokInputBoxDetector.detect(try ScreenFixture.screen("grok-11-dashboard"))
                == .noComposer(
                    "Grok Build is showing its dashboard, where a message starts a new agent. Go back to the conversation in the terminal first."
                ))
    }

    /// The dashboard's view of an agent shows that agent's own box, read
    /// as the conversation's own view is; whether the agent is this
    /// conversation is the session check's to say. At the phone's 62
    /// columns the footer stops before `Shift+Tab:mode` (grok-40 to
    /// grok-42, 1.0.62, live), so an empty box without the placeholder has
    /// prompt focus.
    @Test(arguments: [
        "grok-40-agent-view-other-62", "grok-41-agent-view-this-62", "grok-42-agent-view-dispatched-62",
    ])
    func theDashboardsViewOfAnAgentReadsItsBox(stem: String) throws {
        let screen = try ScreenFixture.screen(stem)

        #expect(GrokScreen(screen).isDashboardOverlay)
        #expect(GrokInputBoxDetector.detect(screen) == .empty(placeholder: nil))
    }

    /// Synthetic, by the 1.0.45 source and the captures' chrome: the view
    /// holds what the conversation's own view holds. Grok sets
    /// `Ctrl+\:dashboard` first in the footer and `‹ i/n ›` in the header
    /// while there are other agents to cycle to, which a pending press
    /// leaves alone, and draws the same placeholder without focus.
    @Test func theDashboardsViewOfAnAgentHoldsWhatTheOwnViewHolds() {
        let header = "Se… │ main /p/t/hcl/pr… 22K / 256K │ ‹ 1/3 › │ [Dashboard]"
        let hints = [
            "Ctrl+\\:dashboard", "Ctrl+[/]:prev/next agent", "Ctrl+x:stop", "Shift+Tab:mode", "Ctrl+.:shortcuts",
        ]
        let unfocused = GrokScreenBuilder(columns: 62, placeholder: "Build anything", hints: hints, header: header)
        let typed = GrokScreenBuilder(columns: 62, typed: "Reply with the word lime.", hints: hints, header: header)
        let working = GrokScreenBuilder(
            columns: 62, status: .init(label: "Thinking…"), typed: "Reply with the word lime.", hints: hints,
            header: header)
        let wide = GrokScreenBuilder(hints: hints, header: header)
        let pending = GrokScreenBuilder(columns: 62, footer: "Ctrl+c:press again to quit", header: header)

        for builder in [unfocused, typed, working, wide, pending] {
            #expect(GrokScreen(builder.screen).isDashboardOverlay)
        }
        #expect(GrokInputBoxDetector.detect(unfocused.screen) == .disabled(Self.unfocused))
        #expect(GrokInputBoxDetector.detect(typed.screen) == .text("Reply with the word lime."))
        #expect(GrokInputBoxDetector.detect(working.screen) == .text("Reply with the word lime."))
        #expect(GrokInputBoxDetector.detect(wide.screen) == .empty(placeholder: nil))
        #expect(
            GrokInputBoxDetector.detect(pending.screen)
                == .disabled(
                    "Grok Build is waiting for a second key press (\u{201C}Ctrl+c:press again to quit\u{201D}). Wait a second, then send again."
                ))
        // The conversation's own view, its header without the switcher.
        let own = GrokScreenBuilder(header: "master ~/s/cap-grok-a/proj  26K / 256K │ [Dashboard]")
        #expect(!GrokScreen(own.screen).isDashboardOverlay)
        #expect(GrokInputBoxDetector.detect(own.screen) == .empty(placeholder: nil))
    }

    @Test(arguments: [
        "grok-07-slash-popup", "grok-08-at-popup", "grok-09-model-picker", "grok-10-btw", "grok-21-resume-picker",
        "grok-22-rewind-picker",
    ])
    func menusAndPickersHoldTheSend(stem: String) throws {
        let shown = [
            "grok-07-slash-popup": "❯ /memory", "grok-08-at-popup": "❯ README.md",
            "grok-09-model-picker": "❯ 256k Default", "grok-10-btw": "╭─ /btw Quick aside",
            "grok-21-resume-picker": "┌─ Resume session", "grok-22-rewind-picker": "Rewind to which turn?",
        ]

        let expected = try #require(shown[stem])

        let state = GrokInputBoxDetector.detect(try ScreenFixture.screen(stem))

        guard case .overlay(let row) = state else {
            Issue.record("Expected an overlay, got \(state)")
            return
        }
        #expect(row.contains(expected))
    }

    @Test func aPendingDoublePressHolds() {
        let screen = GrokScreenBuilder(footer: "Ctrl+c:press again to quit").screen

        #expect(
            GrokInputBoxDetector.detect(screen)
                == .disabled(
                    "Grok Build is waiting for a second key press (\u{201C}Ctrl+c:press again to quit\u{201D}). Wait a second, then send again."
                ))
    }

    /// A message would end these waits and cancel the rest of the turn.
    /// At 40 columns the subagent label is cut to `Waiting for…`, which a
    /// model wait also reads; the dock's Subagents section tells them apart.
    @Test(arguments: [
        "grok-26-waiting-subagent", "subagent wait at 120 columns (synthetic)",
        "subagent wait at 62 columns (synthetic)", "subagent wait at 40 columns (synthetic)",
        "two subagents at 40 columns (synthetic)",
        "Waiting for 2 subagents… (synthetic)", "Waiting on task output… (synthetic)", "Waiting on tasks… (synthetic)",
        "Sleeping… (synthetic)", "a task's subject with Enter to send now (synthetic)", "a parked wait (synthetic)",
        "a parked wait with background work at 40 columns (synthetic)", "a parked wait with a queue (synthetic)",
    ])
    func holdsDuringEverySendableWait(label: String) throws {
        #expect(GrokInputBoxDetector.detect(try Self.screen(label)) == .disabled(Self.waiting))
    }

    /// A message queues behind these, so the send goes.
    @Test(arguments: [
        "a model wait at 40 columns (synthetic)", "a prompt not yet accepted (synthetic)",
        "background work while idle (synthetic)",
    ])
    func otherWaitsDoNotHold(label: String) throws {
        #expect(GrokInputBoxDetector.detect(try Self.screen(label)) == .empty(placeholder: nil))
    }

    @Test(arguments: ["grok-05-queued", "grok-26-waiting-subagent"])
    func findsTheSpinnerRowAboveDockRows(stem: String) throws {
        let queued = stem == "grok-05-queued"
        let text = try ScreenFixture.text(stem)
        let footer = try #require(ANSIScreenDecoder.decode(text).rows.last { !$0.isBlank }?.index)
        // The footer as captured, cut after its first hint, and gone.
        let variants = [nil, SGR.reset + "  Shift+Tab:mode", ""].map { replacement -> String in
            var rows = text.components(separatedBy: "\r\n")
            if let replacement { rows[footer] = replacement }
            return rows.joined(separator: "\r\n")
        }

        for variant in variants {
            let screen = GrokScreen(ANSIScreenDecoder.decode(variant))
            #expect(screen.statusRow?.row == 36)
            #expect(screen.statusRow?.label == (queued ? "Sleep 40 seconds then echo two…" : "Waiting for subagent…"))
            #expect(screen.dockSections == [queued ? "Queued 1" : "Subagents 1"])
        }
    }

    @Test func aCutLabelKeepsItsStatusRow() throws {
        let screen = GrokScreen(Self.queued(columns: 40).screen)

        #expect(screen.statusRow?.label == "Sleep 40 …")
        #expect(screen.statusRow?.trailer == "18s ⇣25.8k [↓][stop]")
        #expect(screen.dockSections == ["Queued 1"])
        #expect(GrokScreen(Self.wait("Cancelling…").screen).isCancelling)
        #expect(!GrokScreen(try ScreenFixture.screen("grok-03-working")).isCancelling)
    }

    @Test(arguments: ["grok-05-queued", "grok-06-esc-toast"])
    func toastsAndQueueRowsDoNotHold(stem: String) throws {
        #expect(GrokInputBoxDetector.detect(try ScreenFixture.screen(stem)) == .empty(placeholder: nil))
    }

    @Test func multilineModeHolds() {
        let multiline =
            "Grok Build is in /multiline mode, where Enter adds a line instead of sending. Turn it off in the terminal with /multiline."

        #expect(GrokInputBoxDetector.detect(GrokScreenBuilder(multiline: true).screen) == .disabled(multiline))
        #expect(
            GrokInputBoxDetector.detect(GrokScreenBuilder(columns: 40, typed: "two\nlines", multiline: true).screen)
                == .disabled(multiline))
    }

    /// The 1.0.45 source sets the label in the bottom border, in the
    /// model's place; the spec expected it in the top one.
    @Test func editingAQueuedMessageHolds() {
        let editing = "Grok Build is editing a queued message. Finish it in the terminal first."
        let bottom = GrokScreenBuilder(
            typed: "After that, reply with the word three.", bottomLabel: "editing queued #1",
            hints: ["Enter:save", "Esc:cancel"])
        let top = GrokScreenBuilder(typed: "After that", topLabel: "editing queued #2")

        #expect(GrokInputBoxDetector.detect(bottom.screen) == .disabled(editing))
        #expect(GrokInputBoxDetector.detect(top.screen) == .disabled(editing))
    }

    /// Minimal mode draws a flush-left prompt with no box (1.0.62, live).
    @Test func minimalModeHolds() {
        let minimal =
            "Grok Build is in minimal mode, which Chat can't read. Switch back with /fullscreen in the terminal."
        let idle = ScreenFixture.synthetic(
            ["❯ Reply with the word kiwi.", "", "kiwi", "", "", "", "", "minimal · /fullscreen to go back · /help",
             "❯ ", "Grok 4.7 Fast (high) · ctrl+o transcript"])
        let working = ScreenFixture.synthetic(
            ["❯ Reply with the word kiwi.", "", "", "", "", "", "", "⠋ Thinking… 1.2s", "❯ ",
             "Grok 4.7 Fast (high) · ctrl+o transcript"])

        #expect(GrokInputBoxDetector.detect(idle) == .disabled(minimal))
        #expect(GrokInputBoxDetector.detect(working) == .disabled(minimal))
    }

    /// Cards in the composer's place, with past prompts at the full-screen
    /// view's indent, are not minimal mode.
    @Test func noBoxIsUnknown() throws {
        let scrollback = ScreenFixture.synthetic(
            ["", "     ❯ Reply with the word kiwi.", "", "     kiwi", "", "", "", "",
             "     ❯ Reply with the word plum."])
        let screens = [
            scrollback, try ScreenFixture.screen("grok-12-permission-command"),
            try ScreenFixture.screen("grok-23-rewind-confirm"),
        ]

        let unknown = InputBoxState.unknown("Heeler can't find Grok Build's input box on screen.")
        for screen in screens {
            #expect(GrokInputBoxDetector.detect(screen) == unknown)
        }
    }
}
