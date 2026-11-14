# 0040: Conversation titles use native Agent commands

Status: accepted

## Context

herdr's `agent.rename` changes its restricted management alias, not the Agent's conversation title. Each harness owns its own title and persists it differently. Direct transcript or database writes can race a running harness and do not update its in-memory state.

## Decision

Keep the existing native More menu and list context menu. Both open one Rename sheet, also available from the terminal detail. Save applies the typed conversation title. Generate Automatically is a second, immediate rename action: it invokes native generation and dismisses only after confirmation. Cancel before either action writes nothing; dismissal is disabled while an action is in flight.

`AgentTitleRenameStore` owns validation, native command/dialog sequencing, and result reconciliation. It sends through the existing Console projection and SSH transport; it never writes harness files. Supported Herdr TUI programs are Claude Code, Codex, Pi, Oh My Pi, Grok Build, OpenCode, and Antigravity CLI. herdr-core does not yet offer this action because its Agent identity and typing contracts need a separate adapter. Other programs do not offer Rename.

- Claude, Codex, OMP, Grok and Antigravity CLI take `/rename <title>`; Pi takes `/name <title>`.
- OpenCode 2.0.32 uses its Ctrl+R Rename session dialog. Every field change is preceded by a same-session and dialog check, and Enter follows an exact field read-back.
- Claude, Codex and OMP expose native generation via `/rename`. Codex's generated suggestion requires a separately checked confirmation. Pi, Grok, OpenCode and Antigravity CLI keep manual editing while the generation button explains that generation is unavailable here. This does not claim those programs can never support another generation API.

The operation pins terminal, pane, workspace, tab, program, connection generation, and the reported conversation. An absent session or a nonempty/unrecognized input box sends nothing. It starts only for an idle/done Agent. A per-Agent lease prevents concurrent rename operations and other Console input on this device. Fresh reads precede writes; there is no atomic session-conditional input RPC, so another client changing the program between a read and write remains a protocol limitation.

Result confirmation reads the same Agent's title rather than waiting for a working-to-done transition. Synchronous commands may never report working: Claude's successful manual rename returned `agent_prompt_stalled` in local testing with `--wait`. Successful confirmation refreshes the normal Console snapshot; no local title override is invented. An unconfirmed write is never retried and disables further mutations until the user checks the terminal and reopens the sheet. A newly observed native generation failure preserves the draft and allows manual saving.

## Evidence and limits

Local command observations used herdr 0.9.5, Claude Code 2.1.318, Codex 0.166.0, Pi 1.4.0, OMP 18.12.3, Grok 1.0.70 and OpenCode 2.0.32. Both successful generation and a native generation failure were observed with OMP; failures are surfaced rather than replaced by a fixed title. Native screens can change between versions: unfamiliar dialogs fail closed. OpenCode's OSC title truncates long names; confirmation uses its known formatting, not arbitrary substring matching. Programs with terminal-title reporting disabled cannot provide this confirmation.

Behavior coverage lives in `AgentTitleRenameTests`. Explicitly configured live acceptance uses `AgentTitleRenameLiveTests` over real SSH and disposable Agents; it is separate from the ordinary test lane and from visual/device acceptance.
