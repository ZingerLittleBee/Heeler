import Foundation

@testable import Heeler

/// Captured Agent screens under `ChatFixtures/screens/`, addressed by stem:
/// `claude-27-n1-narrow-bash` reads `screens/claude/claude-27-n1-narrow-bash.ansi`.
enum ScreenFixture {
    static let claude = [
        "claude-00-trust", "claude-01-ready", "claude-02-c1-bash-blocked", "claude-03-c1-focus-no",
        "claude-03-bash-touch-permission", "claude-04-c1-tab-on-no", "claude-05-c1-pasted-feedback",
        "claude-06-c2-tab-on-yes", "claude-07-c2-pasted", "claude-08-c4-auq-q1",
        "claude-09-c4-toggled", "claude-10-c4-focus-next", "claude-11-c4-q2",
        "claude-12-c4-q2-digit3", "claude-13-c4-q2-pasted", "claude-14-c4-review",
        "claude-15-c9-enterplanmode", "claude-16-c6-exitplan-1", "claude-17-c6-digit3",
        "claude-18-c6-pasted", "claude-19-c6-exitplan-2", "claude-20-c6-pasted-2",
        "claude-21-c6-after", "claude-22-c7-edit", "claude-23-c7-after-esc",
        "claude-24-c8-webfetch", "claude-25-c8-after-digit3", "claude-26-c10-subagent-ask",
        "claude-27-n1-narrow-bash", "claude-28-n1-narrow-bash-later", "claude-29-c3-after-immediate",
        "claude-30-par-first", "claude-31-par-second", "claude-32-c7-phone-bash-blocked",
        "claude-33-c7-phone-focus-no", "claude-34-c7-phone-tab-on-no", "claude-35-c7-phone-pasted-truncated",
        "claude-36-c7-phone-yes-blocked", "claude-37-c7-phone-yes-pasted-wrapped",
        "claude-38-c8-phone-plan-stale-call", "claude-39-c8-phone-question-titled-rule",
        "claude-40-c8-phone-review-titled-rule", "claude-41-c8-phone-question2-padded-rule",
        "claude-42-c8-phone-question-previews", "claude-43-c12-read-file",
    ]

    static let codex = [
        "codex-00-ready", "codex-01-x1-exec", "codex-02-x2-patch", "codex-03-x2-after-esc",
        "codex-04-x3-q1", "codex-05-x3-q2", "codex-06-x3-q2-up", "codex-07-x3-q2-pasted",
        "codex-08-x4-async-collapsed", "codex-09-x4-expanded", "codex-10-x4-after-digit",
        "codex-11-x4-after-skip", "codex-12-x5-narrow-exec", "codex-13-par-first",
        "codex-14-par-second", "codex-15-x6-mcp-tool-list", "codex-16-x7-phone-question-pointed",
        "codex-17-x7-phone-question-notes", "codex-18-x7-phone-async-countdown", "codex-19-x3-implement-plan",
        "codex-20-x8-trust", "codex-21-x8-phone-trust", "codex-22-x8-phone-trust-focus-quit",
        "codex-23-x8-trust-command-center",
    ]

    static let pi = [
        "pi-03-trust-1s", "pi-06-empty-editor-119", "pi-08-auth-error-idle", "pi-09-slash-popup",
        "pi-10-slash-pr-popup", "pi-11-nonempty-after-popup-esc", "pi-12-nonempty-editor",
        "pi-13-skill-invoked", "pi-14-compact-0.25s", "pi-16-empty-editor-120-attached",
        "pi-17-empty-editor-40-attached", "pi-19-slash-popup-40", "pi-20-nonempty-40",
        "pi-31-working-empty-120", "pi-32-working-draft-120", "pi-33-retry-countdown-draft",
        "pi-34-steer-queued-empty", "pi-35-steer-queued-tool", "pi-36-steer-back-in-editor",
        "pi-37-working-empty-40", "pi-38-working-draft-40", "pi-39-compacting-empty",
        "pi-40-phone-extended-steer", "pi-41-compact-nothing", "pi-42-compact-nothing-62",
    ]

    static let omp = [
        "omp-01-startup-empty-119", "omp-02-empty-120-before-first", "omp-03-empty-40-before-first",
        "omp-05-qa-working-1s", "omp-07-empty-40-after-first", "omp-08-empty-120-after-first",
        "omp-09-tool-working-3s", "omp-14-slash-popup", "omp-16-compact-space-after-enter",
        "omp-17-compact-space-pre-enter-150ms", "omp-18-compact-nospace-150ms",
        "omp-19-compact-nospace-1s", "omp-21-after-exit-shell", "omp-23-approval-a-ctrlq-early",
        "omp-24-approval-a-dialog", "omp-24-approval-d-typed-abc",
        "omp-24-approval-e-enter-deny-and-send", "omp-26-approval-b-idle", "omp-27-ask-a-dialog",
        "omp-27-ask-b-after-digit2", "omp-27-ask-c-after-down", "omp-27-ask-e-idle",
        "omp-28-ask2-a-dialog", "omp-28-ask2-b-after-enter-q1", "omp-28-ask2-c-submit-page",
        "omp-28-ask2-e-after-esc-2s", "omp-29-guard-a-draft-while-working",
        "omp-29-guard-b-ask-with-draft", "omp-29-guard-c-after-enter", "omp-29-guard-f-idle",
        "omp-30-plan-mode-on", "omp-31-plan-review", "omp-32-plan-after-esc", "omp-33-after-exit-2",
        "omp-34-ask-multi-62", "omp-35-compact-nothing-62", "omp-36-approval-edit-18-12",
        "omp-37-approval-session-a-after-down", "omp-37-approval-session-b-draft",
    ]

    static let grok = [
        "grok-01-idle-empty", "grok-02-idle-draft", "grok-03-working", "grok-04-working-draft",
        "grok-05-queued", "grok-06-esc-toast", "grok-07-slash-popup", "grok-08-at-popup",
        "grok-09-model-picker", "grok-10-btw", "grok-11-dashboard", "grok-12-permission-command",
        "grok-13-permission-compound", "grok-14-permission-edit", "grok-15-question",
        "grok-16-subagent-panel", "grok-17-session-new", "grok-18-session-fork", "grok-19-resumed-other",
        "grok-20-welcome", "grok-21-resume-picker", "grok-22-rewind-picker", "grok-23-rewind-confirm",
        "grok-24-restored-draft", "grok-25-fork-question", "grok-26-waiting-subagent", "grok-27-compacting",
        "grok-28-welcome-62", "grok-29-welcome-40", "grok-30-idle-62x20", "grok-31-scrollback-62x20",
        "grok-32-working-62x20", "grok-33-working-scrollback-62x20", "grok-34-working-draft-62",
        "grok-35-permission-subagent-62", "grok-36-permission-command-40", "grok-37-permission-command-62",
        "grok-38-fork-question-62", "grok-39-fork-question-40", "grok-40-agent-view-other-62",
        "grok-41-agent-view-this-62", "grok-42-agent-view-dispatched-62", "grok-43-resumed-from-welcome-120",
        "grok-44-permission-second-subagent-120", "grok-45-compaction-cancelled-62",
    ]

    static let opencode = [
        "opencode-01-home-empty-180", "opencode-02-session-empty-180", "opencode-03-session-draft-180",
        "opencode-04-slash-popup-180", "opencode-05-slash-space-180", "opencode-06-at-popup-180",
        "opencode-07-shell-mode-180", "opencode-08-working-180", "opencode-09-armed-180", "opencode-10-permission-180",
        "opencode-11-permission-right1-180", "opencode-12-permission-right2-180", "opencode-13-question-180",
        "opencode-14-session-picker-180", "opencode-15-subagent-panel-180", "opencode-16-child-view-180",
        "opencode-17-recalled-draft-180", "opencode-18-home-after-new-180", "opencode-19-undo-draft-180",
        "opencode-20-pasted-lines-180", "opencode-21-done-interrupted-180", "opencode-22-home-draft-180",
        "opencode-23-at-space-180", "opencode-24-after-ctrl-u-180", "opencode-25-reject-feedback-180",
        "opencode-26-session-command-draft-180", "opencode-27-permission-shell-180",
        "opencode-28-permission-shell-right1-180", "opencode-29-permission-shell-next-180",
        "opencode-30-home-empty-62", "opencode-31-home-draft-62",
        "opencode-32-session-empty-62", "opencode-33-wrapped-draft-62", "opencode-34-pasted-lines-62",
        "opencode-35-working-62", "opencode-36-armed-62", "opencode-37-permission-long-62",
        "opencode-38-question-long-62", "opencode-39-slash-popup-62", "opencode-40-shell-mode-62",
        "opencode-41-subagent-panel-62", "opencode-42-reject-feedback-62", "opencode-43-queued-dock-62",
    ]

    static let agy = [
        "agy-00-trust-prompt-191x49", "agy-01-welcome-after-attach-120x40", "agy-02-idle-empty-120x40",
        "agy-03-ctrlc-idle-once-120x40", "agy-04-typed-after-ctrlc-120x40", "agy-05-esc-idle-draft-120x40",
        "agy-06-esc-esc-idle-draft-120x40", "agy-07-ctrlc-idle-draft-120x40",
        "agy-09-welcome-after-trust-answered-elsewhere-190x49", "agy-10-trust-prompt-no-selected-190x49",
        "agy-11-trust-prompt-no-selected-62x41", "agy-12-trust-prompt-no-selected-40x30",
        "agy-13-first-screen-welcome-120x40", "agy-14-idle-draft-oneline-120x40",
        "agy-15-idle-draft-wrapped-120x40", "agy-16-idle-draft-multiline-120x40",
        "agy-17-prompt-newline-just-sent-120x40", "agy-18-idle-after-reply-120x40", "agy-19-help-shortcuts-120x40",
        "agy-20-help-commands-tab-120x40", "agy-25-slash-popup-120x40", "agy-26-slash-popup-filtered-co-120x40",
        "agy-27-slash-popup-after-esc-120x40", "agy-28-at-popup-120x40", "agy-29-at-popup-120x40",
        "agy-30-perm-run-command-default-120x40", "agy-31-perm-run-command-default-40x30",
        "agy-31-perm-run-command-default-62x20", "agy-31-perm-run-command-default-62x41",
        "agy-32-perm-after-digit2-120x40", "agy-33-working-with-draft-120x40",
        "agy-34-working-submitted-while-working-120x40", "agy-35-done-after-queued-120x40",
        "agy-36-done-final-120x40", "agy-38-esc-while-working-120x40", "agy-39-ctrlc-while-working-120x40",
        "agy-41-ask-question-single-120x40", "agy-42-ask-question-single-40x30", "agy-42-ask-question-single-62x20",
        "agy-42-ask-question-single-62x41", "agy-43-ask-question-after-digit2-120x40",
        "agy-44-ask-question-multi-120x40", "agy-45-ask-question-multi-q2-120x40",
        "agy-46-ask-question-multi-after-esc-120x40", "agy-47-perm-file-edit-default-120x40",
        "agy-48-perm-file-edit-default-40x30", "agy-48-perm-file-edit-default-62x20",
        "agy-48-perm-file-edit-default-62x41", "agy-49-prompt-sent-into-edit-dialog-120x40",
        "agy-50-after-edit-accepted-by-prompt-120x40", "agy-51-perm-run-command-after-esc-120x40",
        "agy-52-perm-run-command-amend-120x40", "agy-54-idle-after-esc-amend-heeler-client-59x41",
        "agy-55-perm-run-command-190x49", "agy-56-perm-run-command-after-digit4-190x49", "agy-57-idle-empty-62x41",
        "agy-58-idle-draft-oneline-62x41", "agy-59-idle-draft-wrapped-62x41", "agy-60-slash-popup-62x41",
        "agy-61-at-popup-62x41", "agy-62-help-shortcuts-62x41", "agy-63-idle-empty-40x30",
        "agy-63-idle-empty-62x20", "agy-64-idle-draft-wrapped-40x30", "agy-64-idle-draft-wrapped-62x20",
        "agy-65-slash-popup-40x30", "agy-65-slash-popup-62x20", "agy-66-working-nodraft-62x41",
        "agy-67-working-tool-running-62x41", "agy-68-working-with-draft-62x41",
        "agy-69-working-draft-entered-then-perm-dialog-62x41", "agy-70-working-queued-after-approve-62x41",
        "agy-71-working-queued-edit-up-62x41", "agy-72-working-altm-send-now-62x41", "agy-73-done-after-altm-62x41",
        "agy-74-compacting-or-after-62x41", "agy-75-after-compact-62x41", "agy-76-mode-cycle-1-120x40",
        "agy-76-mode-cycle-2-120x40", "agy-76-mode-cycle-3-120x40", "agy-76-mode-cycle-4-120x40",
        "agy-77-accept-edits-run-command-120x40", "agy-78-auto-mode-result-120x40",
        "agy-79-plan-mode-result-120x40", "agy-80-artifact-review-ctrl-r-120x40",
        "agy-81-artifact-review-after-y-120x40", "agy-82-plan-approved-result-120x40",
        "agy-83-plan-edit-rejected-120x40", "agy-84-footer-modes-40x30-40x30", "agy-84-footer-modes-62x20-62x20",
        "agy-84-footer-modes-62x41-62x41", "agy-85-model-picker-120x40", "agy-87-perm-after-ctrlc-120x40",
        "agy-88-exit-with-conversation-120x40", "agy-89-warning-notice-bad-model-120x40",
        "agy-90-first-screen-welcome-40x30", "agy-90-first-screen-welcome-62x20",
        "agy-90-first-screen-welcome-62x41", "agy-91-bang-typed-62x41", "agy-92-up-on-empty-box-62x41",
        "agy-93-bash-mode-with-text-62x41", "agy-94-working-nodraft-40x30", "agy-95-working-with-draft-40x30",
        "agy-96-working-queued-40x30", "agy-97-esc-with-queued-40x30", "agy-98-working-nodraft-62x20",
    ]

    /// The Claude and Codex captures that the dialog and input-box suites walk.
    /// Pi, Oh My Pi, Grok Build, OpenCode and Antigravity CLI captures stay
    /// out so those suites keep their expectations.
    static let all = claude + codex

    static func path(_ stem: String) -> String {
        "screens/\(program(stem).rawValue)/\(stem).ansi"
    }

    static func text(_ stem: String) throws -> String {
        try ChatFixture.text(path(stem))
    }

    static func screen(_ stem: String) throws -> ANSIScreen {
        ANSIScreenDecoder.decode(try text(stem))
    }

    /// The program that drew a capture.
    static func program(_ stem: String) -> ChatProgram {
        if stem.hasPrefix("codex-") { return .codex }
        if stem.hasPrefix("pi-") { return .pi }
        if stem.hasPrefix("omp-") { return .omp }
        if stem.hasPrefix("grok-") { return .grok }
        if stem.hasPrefix("opencode-") { return .opencode }
        if stem.hasPrefix("agy-") { return .agy }
        return .claude
    }

    /// A screen built from raw ANSI rows, for states no capture shows yet.
    static func synthetic(_ rows: [String]) -> ANSIScreen {
        ANSIScreenDecoder.decode(rows.joined(separator: "\r\n"))
    }
}

/// SGR spellings for synthetic rows, matching what the captures use.
enum SGR {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let dim = "\u{1B}[2m"
    static let italic = "\u{1B}[3m"
    static let reverse = "\u{1B}[7m"

    static func fg(_ red: Int, _ green: Int, _ blue: Int) -> String {
        "\u{1B}[38;2;\(red);\(green);\(blue)m"
    }

    static func bg(_ red: Int, _ green: Int, _ blue: Int) -> String {
        "\u{1B}[48;2;\(red);\(green);\(blue)m"
    }

    /// Claude's dark-theme roles.
    static let claudeInactive = fg(153, 153, 153)
    static let claudeAccent = fg(177, 185, 249)
    static let claudePromptBorder = fg(136, 136, 136)

    /// A Claude input-box rule `width` cells wide.
    static func claudeRule(_ width: Int) -> String {
        reset + claudePromptBorder + String(repeating: "─", count: width) + reset
    }
}
