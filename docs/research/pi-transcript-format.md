# Pi and Oh My Pi transcript observations

Versioned source observations:

- Pi coding-agent 1.2.0, source commit
  `7d75a0e3eb273dff753d49c066ea29fbe7b3b6f6`:
  [session manager](https://github.com/earendil-works/pi/blob/7d75a0e3eb273dff753d49c066ea29fbe7b3b6f6/packages/coding-agent/src/core/session-manager.ts),
  [stock editor](https://github.com/earendil-works/pi/blob/7d75a0e3eb273dff753d49c066ea29fbe7b3b6f6/packages/tui/src/components/editor.ts).
- Oh My Pi package 18.10.4, `src/session/session-entries.ts`,
  `session-manager.ts`, `session-paths.ts`, and pi-tui's
  `components/composer/box.ts` and `pi.ts`:
  [upstream source repository](https://github.com/can1357/oh-my-pi).
- The herdr Pi extension `herdr-agent-state.ts` reports
  `source: herdr:pi`, `agent: pi`, preferring `agent_session_path` over
  `agent_session_id`. The existing herdr 0.9.3 observations in
  [compatibility notes](../agents/herdr-compatibility.md) record `kind: path`
  for Pi and OMP; [official integrations](https://herdr.dev/docs/integrations/)
  describe the two separate integrations.

## Identity and location

The native session has a UUID. The JSONL file normally lives under
`~/.pi/agent/sessions/<encoded-cwd>/<timestamp>_<UUID>.jsonl` or OMP's own
`~/.omp/agent/sessions` tree. OMP also uses home-relative project keys. Exact
paths reported by herdr cover custom agent roots and custom session directories
without guessing environment variables. Only official matching source/agent
pairs bind. Paths must be absolute JSONL files with no dot traversal or control
characters. All reads use the existing SFTP seam; no reported path becomes
shell code.

Pi starts with `{type: session, version: 3, id, cwd}`. OMP 18.10.4 can put a
fixed-width `{type: title, ...}` slot before that header. Locate validates the
header (including its UUID for UUID lookup). Versions 2 and 3 are supported;
legacy v1 and unknown future versions show an unavailable explanation.

Neither program writes the file when the session starts (live on Pi 0.85.1
and OMP 18.11.1 with herdr 0.9.5, 2026-10-15). Pi wrote the session header, model
and thinking records, the prompt and the first reply in one write; OMP did the same
with its title slot, a `system-prompt-digest` custom record and a
`credential_pin`, or wrote at the first `tool_execution_start` when that tool
needed approval. A Pi session that never got a prompt left no file. OMP
18.11.1 rewrote its title slot in place (same inode) and appended
`title_change{source: auto}`. It rewrote the whole file atomically (new inode)
once, after an answered `ask`: the session header gained `title` and
`titleSource`, earlier assistant messages gained `errorId: 0`, and an empty
`branch_summary` was appended. Two turns that re-read the same file appended
only, unlike 18.10.4. Chat therefore identifies a Pi/OMP file by its header's
session id, not by its first bytes.

## Tree and content

Entries have `id`, `parentId`, `timestamp`, and `type`. Replay the last
selected leaf back through parents; invisible extension and metadata entries
are still ancestry links. OMP's late `model_usage` may carry `activeLeafId`,
which restores the active leaf rather than selecting the usage record's
branch. Incremental append and earlier-history prepend converge by file offset.

`message.message.role` is `user`, `assistant`, or `toolResult`. User content
may be a string or blocks. Assistant blocks include `text`, `thinking`, and
`toolCall` (`id`, `name`, `arguments`). Results pair by `toolCallId`, carry
`isError`, and expose capped text previews; an expanded result re-reads its
exact line. Images are counted, not decoded from base64. A `read` of an
image file begins its result text with `Read image file [<mime>]`, then an
`image` block unless the image could not be attached; Pi 0.85.1 records the
path only in the call's `path` argument, relative to the session's `cwd` when
not absolute (`dist/core/tools/read.js`), and Oh My Pi 18.12.1 also names the
resolved file in the result's `details.mediaPath` and stores the image as
`blob:sha256:<hash>` (live 2026-10-18; 18.12.3 the same on 2026-11-02, the
image re-encoded as `image/webp`). Tool calls without
results retain activity-derived running/blocked/interrupted status. Assistant
`stopReason` ends turns; `aborted` and `error` show notices.

`compaction` inserts a separator and keeps earlier visible history.
`branch_summary` and OMP `reset_boundary` show notices; summaries are
Markdown, and the separator and notice preview them as plain lines (headings
without `#`, list items without task boxes, HTML blocks such as
`<read-files>` dropped), while Copy keeps the text as written. Displayable custom
extension messages become notices; hidden extension state remains invisible.
Unknown record types remain tree links and are counted in diagnostics.

Observed live on 2026-10-15 with Pi 0.85.1 and Oh My Pi 18.11.1 on herdr
0.9.5 (excerpts in the `pi/auth-error-skill.jsonl` and
`omp/approvals-asks-plan.jsonl` Chat fixtures):

- Pi records `/skill:name args` as a user message holding the expanded
  `<skill name="…" location="…">` block, then a blank line and the
  arguments, before the model call. Chat parses it as Pi does, shows
  `/name args`, and matches the echo as `/skill:name args`. OMP records the
  same invocation as a `custom_message` with `customType: skill-prompt`,
  `attribution: user` and the submitted text in `details.prompt`; Chat treats
  it as the turn's prompt and never shows the expanded skill.
- Whether a call without a result is still running or Blocked follows the
  stop reason of the branch's last assistant message, whatever opened the
  turn.
- OMP `ask` arguments are `questions[{id, question, options[{label,
  description, preview}], header, multi, recommended}]`; absent fields are
  JSON null. The result's `details.selectedOptions` holds one question's
  answer, `details.results[{id, selectedOptions}]` several. A denied approval
  results in `Tool call denied by user: <tool>` and a dismissed question in
  `Ask tool was cancelled by the user`, both `isError`; Chat reads them as
  declined.
- Pi's Esc during a tool records the result `Command aborted` and then an
  empty assistant message with `stopReason: error` and `errorMessage: This
  operation was aborted`. A provider error has the same empty shape, so only
  that message tells an interruption from an error.
- OMP's plan proposal records the `write xd://propose` result `Plan ready
  for review.`, then an empty assistant message with `stopReason: aborted`
  and `errorMessage: __omp.silent_abort__`. Chat ends the turn normally with a
  plan-ready notice instead of an interruption, and the `xd://propose` call
  and its result (`details.xdev.tool: propose`) show no row and count no
  file.
- OMP's plan file is `local://<slug>-plan.md`, which 18.11.2 resolves to
  `<session file without .jsonl>/local/<slug>-plan.md` in the session
  directory (live 2026-10-18). Its `write` and `read` rows show the
  `local://` path from their arguments; a free-form `edit` names it only in
  its patch header (`[local://append-delta-plan.md#7A3E]`), and its result's
  `details.path` is the resolved absolute path. Chat titles that edit by
  the `local://` name its patch gave the file.
- OMP 18.11 mounts discoverable tools (MCP tools, `generate_image`,
  `report_issue`) as `xd://<tool>` devices when `tools.xdev` is on (the
  default), driven by `write` with the tool's JSON arguments in `content`;
  their results carry `details.xdev.tool`. Chat shows such a call as a row for
  that tool, not as a file write (read from the 18.11.2 binary's strings on
  2026-10-18; not captured live).
- OMP's `write` result records only `Successfully wrote N bytes` and no diff,
  and says nothing of what the file held before. Chat shows the call's
  `content` as an all-added diff with the file marked written, re-reading it
  from the call's line, and a group counts it as "Wrote N files".
- OMP records `$ code` typed in its prompt as a `pythonExecution` message
  (`code`, `output`), as Pi records `!` as `bashExecution`; Chat shows both as
  notices with capped output.
- OMP's atomic file rewrite appends a `branch_summary` with an empty
  `summary` and `details.kind: discarded-entry-branch`, which Chat hides.
- Tool-call ids can contain `|` (`call…|fc_…` in both programs with these
  models). OMP writes a `custom` `tool_execution_start` record before each
  tool, and a `custom` `session_exit` on `/exit`; neither shows in Chat.
- OMP marks a message that steered a running turn `steering: true`; that
  includes text typed into an approval's prompt and sent with Enter, which
  first records the denied tool result. Pi writes a steer as a plain user
  message right after the running batch's tool results (0–1 ms apart),
  timestamped when it was queued; a steer still queued when Esc interrupts
  the turn is never written.
- Edits: OMP with an OpenAI Codex model calls `edit` with a free-form
  `arguments.input` patch (`customWireName: edit`), and its result's
  `details` hold `path`, `op`, `firstChangedLine`, `oldText`, `newText` and a
  numbered `diff` without hunk headers (` 1|alpha\n-2|beta\n+2|BETA`). Pi
  calls `edit` with `{path, edits[{oldText, newText}]}`, and its result's
  `details` hold `firstChangedLine`, a display `diff` and a unified `patch`.
  Chat reads both as file changes (`PiFileChanges`).
- Pi records `/skill:name` without arguments as the `<skill>` block alone,
  ending at `</skill>`.
- Pi's retryable provider error (`Connection error.`) records an empty
  assistant message with `stopReason: error`; the retried reply's `parentId`
  is that error message, so the error is not the branch's last word. A
  cancelled retry records nothing: Esc during Pi 0.85.1's `Retrying (1/3)`
  countdown prints `Error: Retry failed after 1 attempts: Retry cancelled`
  on the pane only, so Chat ends that turn on the provider error, as it ends
  an exhausted retry.
- Pi's compaction records `{summary, firstKeptEntryId, tokensBefore,
  details{readFiles, modifiedFiles}, usage, fromHook: false}`, with
  `firstKeptEntryId` the last assistant message. `/compact` with nothing to
  compact records nothing in either program. A real compaction of a
  ~10k-token Pi 0.85.1 session (grok-4.5, live 2026-10-18) showed
  "Compacting context... (escape to cancel)" for 10 to 18 s while herdr
  reported the Agent idle, and wrote the record when the row went.

## Input and limits

Pi's standard editor has full-width horizontal rules and a reverse-video
software cursor. OMP's classic box uses a rounded top and a last input row
merged into the bottom border, with a `▏` insertion cursor. OMP 18.10.4 now
defaults to `band`: a filled status row above an unboxed `╰─ ` prompt
(`pi-tui/src/components/composer/band.ts`). herdr 0.9.1's visible ANSI
screen can omit the hardware cursor for this composer.

Live screens (Pi 0.85.1 and OMP 18.11.1 on herdr 0.9.5, now the
`ChatFixtures/screens/pi` and `screens/omp` fixtures) corrected the earlier
source reading:

- OMP 18.11.1's nerd preset starts the band at column 0 with U+E0B6; the
  next segment is U+F0D57 while idle (plan mode included) and a braille
  spinner with seconds while a turn runs or a dialog is Blocked. Before the
  first message the prompt row carries an italic right-aligned hint, `to
  change thinking effort`, which is not a draft. A titled panel such as
  `╭─ Allow tool: bash ─…╮` rests on the band with the spinner and an empty
  `╰─` still below it; an `ask` without a draft replaces the composer, and
  the Plan Review fills the screen with no composer. A multi-select `ask`
  toggles with Space (`space toggle · enter submit`); its generic card's key
  pad has no Space, so toggling stays in the terminal.
- OMP 18.12.1's tool approval lists its choices under the details: `Approve`,
  `Approve <tool> for this session` when the approval policy offers it, and
  `Deny`, which reads `Deny and send message` while the prompt holds a draft.
  The pointer marks the focused row and the footer adds `↑/↓ choose · 󰌑
  select`; under a draft the pointer stays on Deny and the footer drops
  `choose` (fixtures `omp-36`, `omp-37`).
- `/compact ` with a trailing space is completed to `/compact soft ` with grey
  ghost text and not submitted; only an ANSI read tells the ghost text apart.
- Pi's footer is a working-directory row (`/private/tmp/...` outside the home
  directory, cut with `...` at 40 columns) and a stats row such as `$0.000
  (sub) 0.0%/500k (auto)`, directly under the editor's bottom rule. Its
  completion list draws between that rule and the footer, and now marks
  skills and prompt templates `[p]` (project) or `[u]` (user); project
  templates appear there too. While a turn runs the top rule reads
  `── ⠸ Working ───` and the empty editor keeps its reverse-video cursor at
  column 0; a provider-retry countdown keeps a plain rule. Pi's screen uses no
  private-use glyphs.

ADR 0024 records what Chat makes of these: it sends only after positively
reading an empty stock editor or an idle OMP band, holds while an OMP turn
runs, answers OMP's tool approval (18.12's session row included) and
single-select `ask` from Blocked cards with keys rather than digits, and
leaves drafts, completion popups, custom
editors, other panels and unrecognized composer styles to the terminal. Stop
and explicit tools keys retain the existing RPCs.

A separate server compatibility constraint applies to herdr 0.9.1: its
`src/detect/mod.rs` does not recognize the full
`@oh-my-pi/pi-coding-agent/dist/cli.js` path used by OMP's `/restart`.
`src/app/api/agents.rs` then rejects `agent.prompt` with `agent_not_ready`
before writing any input, even though the integration reports the session.
The v0.9.3 source recognizes that package path. With 0.9.1, launching the
existing session with the official `HERDR_AGENT=omp` environment hint can
retain identification without changing other panes or bypassing the RPC guard.

UUID fallback search is bounded and limited to default session roots; custom
roots need herdr's path reference. External blob-backed content, compressed
files and nested subagent transcripts are not followed by this adapter.
Focused tests run scrubbed live screens and JSONL excerpts, plus synthetic
JSONL, through production detectors, parsers, locators, followers and
reducers; the Simulator demo uses synthetic JSONL only. They do not prove a
live Pi/OMP Host's prompt delivery or its extension dialogs.

Preview with `--demo-screenshots --demo-pi-chat`; this replaces two existing
demo Agents with Pi and OMP while keeping the default demo unchanged. Samples
are synthetic and have no Host connection.
