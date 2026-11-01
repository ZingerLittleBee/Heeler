# Chat fixtures

Captured inputs for the native Chat tests. The test bundle carries this
directory as a folder reference (`project.yml`), and
`Tests/HeelerTests/Support/ChatFixture.swift` loads files by their path below
this directory.

## Provenance

All captures come from live probes against an isolated herdr backend on
2026-10-06: herdr 0.9.3 (protocol 22), Claude Code 2.1.291 and Codex 0.160.1.
None came from a personal session.

| Path | Source |
|---|---|
| `claude/probe1-transcript.jsonl` | First probe: Claude Code session with Bash, AskUserQuestion, plan mode and Write permissions |
| `claude/probe2-transcript.jsonl` | Second probe (session `e951205e-24af-4a5e-baa7-3ccbebd2de2c`): declines with and without feedback, notes on approvals, multi-question AskUserQuestion, plan mode, Edit/WebFetch declines, a background subagent, parallel Bash |
| `claude/probe2-subagent.jsonl`, `.meta.json` | The background subagent the second probe launched (`agent-a9985bf0a8b4ebbe3`) |
| `codex/probe1-rollout.jsonl` | First probe: Codex rollout with exec approvals and `request_user_input` |
| `codex/probe2-rollout.jsonl` | Second probe: paginated rollout with approvals, declines, sync and async questions, interrupted turns and parallel commands |
| `omp/approvals-asks-plan.jsonl` | Oh My Pi 18.11.1 session from the 2026-10-15 probes below: approved and denied Bash approvals (one denied with a steering message), answered and cancelled `ask` calls, the empty `branch_summary` an atomic rewrite appends, and a plan proposal ending in `__omp.silent_abort__` |
| `pi/auth-error-skill.jsonl` | Pi 0.85.1 session from the same probes: a provider authentication error and a `/skill:probe-hello world args` invocation recorded as its `<skill>` block |
| `pi/provider-retry.jsonl` | Pi 0.85.1 session from a later 2026-10-15 probe against herdr 0.9.5: a `Connection error.` Pi retried on its own, the retry recorded as the error's reply |
| `pi/summaries.jsonl` | Pi 0.85.1's `branch_summary` and `compaction` records from the 2026-10-17 E2E run (isolated root), summaries verbatim: Markdown headings, task checkboxes and a `<read-files>` block. The messages around them are written for the test |
| `grok/fork-head.jsonl` | Grok Build 1.0.62 on herdr 0.9.5 (2026-10-19): the start of a scratch session made with `/fork` without a worktree, lines 1, 3–6 and 10 of the capture. The first five are the parent's records as the fork copied them, with the fork in `sessionId` and the parent's id still prefixing `eventId`; the last is the fork's own. The dropped lines are the developer's hook records, a copied `background_tasks` record and two more herdr `session_start` records |
| `grok/core-turns.jsonl` | Grok Build 1.0.62 on herdr 0.9.5 (2026-10-19): a scratch session's first four turns, lines 1, 3–5, 7–9, 11–13, 15–17, 19 and 21–24 of the capture: herdr's `session_start` record, a one-line prompt, a three-line prompt, a prompt with the space Chat adds after it, and a turn with a `run_terminal_command` call (its start, input and result), reasoning and a reply in Chinese. The dropped lines are the developer's hook records |
| `grok/cancel-takeover.jsonl` | The same Grok Build and herdr (2026-10-19), lines 1, 3–7, 9–12 and 14–17 of another scratch session's capture: a prompt stopped with Ctrl+C before any output, the prompt that took over its index, and a turn that spawned a subagent and was cancelled with Ctrl+C, the subagent's end written after the turn's. Line 3 is the developer's `user_prompt_submit` hook between the two prompts, its run renamed `project/probe:user_prompt_submit[0].hooks[0]`; the other hook records are dropped |
| `grok/rewind.jsonl` | The same (2026-10-19), lines 1, 3, 5–6, 8–11, 13 and 15–16 of a scratch session's capture: two turns, a `rewind_marker` to prompt 1, and the prompt that reused index 1, the restored draft joined to it. The dropped lines are the developer's hook records and two reasoning records |
| `grok/compaction.jsonl` | Lines 1–6 are lines 139–144 of an earlier capture of `core-turns.jsonl`'s session (2026-10-19): a turn, then a manual `/compact` (`compaction_checkpoint` and `auto_compact_completed`). Lines 7–12 are written for the test in the same session, from event number 606 on: an automatic compaction inside the next turn, recorded as Grok Build's source writes one |
| `grok/dispatch-order.jsonl` | The same (2026-10-19), lines 1–4 of a session dispatched from Grok's dashboard: its prompt is written before herdr's `session_start` record |
| `grok/agent-turns-and-errors.jsonl` | Written for the test, not captured: a skill, a prompt of text, image and text chunks with an `image_dropped` notice, an interjection and a thought written after its turn's end, a retry that gave up and an expired sign-in (each ending its turn with an error), a shell-mode command, a hidden prompt Grok wrote for itself after a background command, fork and resume context wrappers, an unknown record kind, and a cancelled and a failed automatic compaction. The records take the captures' shapes, or Grok Build's source where no capture shows one |
| `grok/reject-and-edit.jsonl` | The same Grok Build and herdr (2026-10-19), lines 97–116 of a scratch session's capture: a `run_terminal_command` call the user rejected, which ended the turn (`PermissionRejected`), a `search_replace` call that created `notes.txt`, and one that changed a line of it, its result carrying the edit's details. No hook records fall in these lines |
| `grok/subagent-todo-question.jsonl` | The same (2026-10-19), lines 18–20, 22–24, 26–28, 35–37, 39, 41–44, 46, 48–49, 51, 53–55, 57, 59–60, 62, 64 and 77 of another scratch session's capture, four turns: a subagent whose `subagent_spawned` and `subagent_finished` records come before the spawn's input update, a `todo_write` call and the `plan` snapshot after it, an `ask_user_question` call answered with its first option, and a `write` call that created `note.txt`. The dropped lines are the developer's hook records, a turn that wrote its plan as prose, two thoughts, and git calls with a message that names the commit |
| `grok/pending-permission.jsonl` | The same (2026-10-19), lines 90–92 of a capture taken while Grok waited for permission to run a command: herdr's `session_start` record, the prompt, and the bare `tool_call` |
| `grok/background-tasks.jsonl` | Written for the test, not captured: a command started in the background, a command Grok moved to the background while it ran, and a subagent spawned in the background, with their `task_backgrounded` and `subagent_spawned` records, then the commands' `task_completed` records (one exited 0, one was killed) and the subagent's `subagent_finished`; then a monitor, whose `task_backgrounded` comes before its input update, whose result holds no output, and whose output comes with a `task_completed` of kind `monitor`. The records take the shapes Grok Build's source writes |
| `grok/failed-tools.jsonl` | Written for the test, not captured: one turn of failed calls, a `tool_execution_failed` error, the tagged failures `FileNotFound`, `FileTooLarge`, `NotADirectory`, `NotFound`, `NoMatchesFound`, `MultipleMatchesFound` and `InvalidInput`, and an MCP call that returned an error. The records take the shapes a census of real failures found; some carry no content |

`host-evidence/` is a separate recording, for the herdr-core session binding of
ADR 0034. `HerdrCoreProgramBinderTests` reads `codex/`, `grok/` and `opencode/`,
`OpenCodeStoreQueryTests` the schemas, and the Pi and Oh My Pi binder tests its `pi`
and `omp` folders through `PiHostEvidence`. No test reads `reply-held.json` or the core
event streams yet. It came from a throwaway Linux VM on
2026-11-01 with herdr-core 0.1.13 and a local fake model behind a dummy key.
Nothing was signed in and it is not from hc-lab, so an account could change
what it shows; `docs/agents/herdr-compatibility.md` says how for each program.
Each `.json` names its harness version, method and what was observed, and holds
process rows shaped for `ScriptedProcessTable.Process`, plus the files as read.

| Path | Source |
| --- | --- |
| `host-evidence/codex/no-daemon.json` | Codex CLI 0.165.0 `--no-daemon`: the process tree and held files at the prompt and after the first reply, and the rollout's `session_meta` |
| `host-evidence/codex/no-daemon-after-new.json` | The same, before `/new` and after a prompt in the new thread: two held root rollouts. Its `observed` text alone says what the first prompt after `/new` leaves, the new thread's lock with no rollout, and the test that uses this says it edits the recording |
| `host-evidence/codex/no-daemon-subagent.json` | The same, with a root and a subagent the fake model spawned |
| `host-evidence/codex/default-daemon.json` | Plain `codex` in two Terminals on one `CODEX_HOME`: the shared daemon, the `HC_SCOPE` it carries and the rollouts it holds |
| `host-evidence/grok/s-flag.json` | Grok Build 1.0.70 `-s`: `active_sessions.json` with one Terminal, with two, and after `/new`, `pid_start` against field 22 of `/proc/<pid>/stat`, and leader mode |
| `host-evidence/opencode/ses-flag-2.2.5.json`, `ses-flag-2.0.32.json` | OpenCode `-s ses…`: its rows in `session_v2`, each message's type and `data` keys, and the service process |
| `host-evidence/opencode/schema-2.2.5.sql`, `schema-2.0.32.sql` | Each version's `opencode.db` schema from `sqlite_master`, whole: 24 tables on 2.2.5, 20 on 2.0.32, with their indexes |
| `host-evidence/pi/session-files-0.85.1.json`, `session-files-1.4.0.json` | Pi `--session-id`, `/new` and no flag: when each session file appeared, its header and line types, and the bare process |
| `host-evidence/omp/breadcrumb-and-session-files.json` | Oh My Pi 18.13.3: the breadcrumb through a process's life and the next one's, session files, the open file, the session lock, and how far the security scan got |
| `host-evidence/omp/session-lock-by-id.json` | Oh My Pi 18.13.3: the lock its process holds while the title is held, and the names its own `tryAcquireSessionLease` binds for the same ids and for invented ids and homes. The hash is not identified |
| `host-evidence/reply-held.json` | All five with the fake model holding each reply, Pi on 0.85.1 and 1.4.0 and OpenCode on 2.0.32 and 2.2.5: what existed during the hold |
| `host-evidence/*/*-core-events.ndjson` | The core's event stream for the same runs, from `scripts/lab/herdr-core-capture.py` |

## Scrubbing

The probe tooling already re-serialized each JSON line, replaced attachment
bodies with `{"type": …, "redacted": true}` and thinking text with
`<redacted>`. Real transcripts are compact JSON, so tests parse lines and
never compare bytes with a live file.

Copying them here also rewrote, with replacements of the same length so
byte offsets and screen columns stay exactly as captured:

- the account name to `developer` (so `/Users/developer` and its project-key
  form `-Users-developer`);
- the probe root `heeler-iso-chat` to `heeler-tmp-chat`.

The 2026-10-15 sessions were re-serialized as compact JSON without
`credentialId`, `providerPayload`, `responseId`, `textSignature`,
`contextSnapshot` and the `credential_pin` hash, with the account name
replaced as above; `pi/provider-retry.jsonl` also drops the encrypted
`thinkingSignature`. Each keeps every line of its session, so tests address
records by line number.

Grok Build captures keep their chosen lines byte for byte, apart from
these replacements:

- Every id (session, prompt, tool call, compaction checkpoint, subagent)
  becomes a synthetic UUIDv7-shaped id (`01900000-0000-7000-8000-0000000000NN`),
  the same one wherever the real id appeared: in a call id's `call-<id>-0`,
  in the `eventId` prefix a fork keeps from its parent, and, without its
  dashes, in a subagent attempt's `at1.<id>`.
- The account name becomes `developer`, also inside the byte arrays Grok
  writes for a command's output. The name has the same length, so
  `total_bytes` still holds.
- The scratch directory the probes ran in becomes `/Users/developer/scratch/`,
  plain and percent-encoded.
- In `subagent-todo-question.jsonl`, the question and options the model
  wrote in Chinese become English scratch text, in the call, its input
  update and the answer. Those three lines are shorter than captured.

The developer's own hook records (`global/settings:` runs) are dropped, except
the one `cancel-takeover.jsonl` keeps under a renamed run; herdr's
`session_start` records stay. The fixtures written for the tests use ids
from the same range only. Searching `grok/` for a UUID outside that range, a
`global/settings` run or the account name, in text or in a byte array, finds
nothing.

Host evidence captures were rebuilt from raw recordings, so unlike the above
they are not byte for byte and offsets do not hold:

- Only `HC_SCOPE` of any process's environment is kept, and its hex becomes a
  counter. No key, prompt, reply or title is kept: `base_instructions` and
  titles read `<scrubbed>`, and messages keep only their type and `data` keys.
- Every UUID, `ses_` and `msg_` id becomes a synthetic one of the same form,
  consistent within a file, including in file names and `HC_SCOPE`. Pids,
  process starts, timestamps and the Oh My Pi lock's hash are as recorded.
- The VM's user becomes `user` (`/home/user`, plain, percent-encoded and in
  session folder names), and its host name and core id go.
- The core events went through the capture script's scrubbing, then the same
  id mapping.

After adding a capture, check that searching this directory for `/Users/`
(other than `/Users/developer`), `ghp_`, `Bearer` and e-mail addresses finds
nothing.

## Screens

`screens/claude/*.ansi` and `screens/codex/*.ansi` are visible-screen reads
(`agent.read` with `source: visible`, `format: ansi`, `strip_ansi: false`)
taken during the same isolated probes, kept as herdr returned them apart from
the scrubbing below: CRLF rows, SGR styling only. Each keeps the stem of its
capture.

- `claude-03-bash-touch-permission.ansi` comes from the first probe; every
  other screen comes from the second.
- Most screens are 120×40. `claude-27` through `claude-31` and `codex-12`
  through `codex-14` were read at 40×30.
- `codex-15-x6-mcp-tool-list` comes from Codex 0.162.1 on herdr 0.9.5
  (2026-10-17), read at 41 columns (app terminal font size 12): the MCP
  tool approval "Allow the probe MCP server to run tool ...", a two-column
  list with the footer `enter to submit | esc to cancel`.
- `codex-16-x7-phone-question-pointed` and `codex-17-x7-phone-question-notes`
  come from Codex 0.162.1 on herdr 0.9.5 (2026-10-17), read at the phone's
  62×40 grid: a `request_user_input` question with the pointer on `None of
  the above`, whose description wraps `(tab)` onto a second reverse row, then
  the same question after Tab and a paste opened its notes (0.162.1 drops a
  paste while the options have focus).
- `codex-18-x7-phone-async-countdown` comes from the same Codex at 62×41:
  `request_user_input_async` questions folded under "Queued follow-up
  inputs" while a command runs, the count row carrying Codex's countdown
  (`? 2 questions · 20s`).
- `codex-19-x3-implement-plan` is derived, not captured: Codex 0.162.1's
  `Implement this plan?` selector after a Plan-mode turn on herdr 0.9.5
  (2026-10-17), rebuilt from that run's plain-text pane read, rows as read,
  with the styles of `codex-06` and `codex-15`: a bold reverse pointed row,
  dim descriptions and footer, and a bold-dim `›` on the history's prompt.
  Replace it with a capture when one is taken.
- `claude-27`, `-28`, `-30` and `-31` keep the live rendering residue after
  option 4 (`No` followed by a stale grey `r you`).
- `claude-32` through `claude-37` come from Claude Code 2.1.301 on herdr
  0.9.5 (2026-10-17), read at the phone's 62×41 grid: a Bash dialog with
  the `Tip:` line, focus on `No`, Tab on `No`, and a pasted note too long
  for its row, cut off with `…` and no cursor cell; then another Bash
  dialog and a note on `Yes` wrapped onto a second row, with the cursor
  cell only on that row.
- `claude-38` is a 2.1.301 plan dialog at the same grid whose call
  recorded the previous plan: Claude wrote the plan file and called
  ExitPlanMode in one message, and `input.plan` kept the file as it was
  before the Write.
- `claude-39` is a 2.1.301 question at the same grid in a named session:
  under the footer Claude draws a rule carrying the session's name.
  `claude-40` is the review page after a multi-select answer: no footer,
  only that rule.
  `claude-41` is the second page of a two-question form: it keeps the
  first page's height, so blank rows sit between its footer and that rule.
  `claude-42` is a question whose options have previews: the preview box
  beside the options and an `n to add notes` hint in a wrapped footer.
- `claude-43-c12-read-file` is derived, not captured: Claude Code 2.1.301's
  `Read file` dialog for a staged upload outside the project, rebuilt at the
  phone's 62-column grid from `claude-32`'s rows and colors and the rows the
  2026-10-17 E2E run's generic card showed (title, dashed rules, the
  `Read(<path>)` call wrapped at the edge, `Do you want to proceed?`, `1. Yes`,
  `2. No`, `Esc to cancel · Tab to amend`). The macOS temporary directory in
  the path is a same-length placeholder. Replace it with a capture when one
  is taken.

Scrubbing used the same same-length replacements as above, so every column
is as captured. The shell prompt on the first row of `claude-00-trust.ansi`
also had its host name replaced by `probe-host-placeholder-01`.

### Pi and Oh My Pi screens

`screens/pi/pi-*.ansi` and `screens/omp/omp-*.ansi` are visible-screen reads
taken the same way on 2026-10-15 against isolated herdr 0.9.5 backends: pi
0.85.1 and Oh My Pi 18.11.1. Each backend had its own socket, but the pane's
`HOME` pointed at the developer's account so both Agents used a real
subscription and real settings; no credential file was read or copied. Each
file keeps the capture's number and name behind the `pi-` or `omp-` prefix.

- Pi's model calls failed authentication, so `pi-03` to `pi-20` show that error
  above the editor; `pi-06` also shows the Update Available box and a working
  directory outside `HOME`.
- `pi-31` to `pi-39` come from a second pi capture on 2026-10-16 after the
  developer logged in again (numbered here, not by capture), so they show real model turns: the Working
  rule, queued steers, a retry countdown and compaction. They are 120
  columns wide except the `-40` ones.
- `pi-40-phone-extended-steer` comes from Pi 0.85.1 on 2026-10-17 at the
  phone's 62 columns: a steer Stop returned to the editor, with text the user
  added after it (`say FIG and also say PEAR`). Its `40` is the capture
  number, not a width.
- `pi-41-compact-nothing` comes from Pi 0.85.1 on herdr 0.9.5 (2026-10-18),
  started with `--no-session` in an empty directory: `/compact` typed into
  the fresh session printed `Error: Compaction failed: Nothing to compact
  (session too small)` above the editor, and the Agent stayed idle.
- `pi-42-compact-nothing-62` and `omp-35-compact-nothing-62` come from Pi
  0.85.1 and Oh My Pi 18.11.2 on herdr 0.9.5 (2026-10-18) at the phone's 62
  columns, after one turn each: the same refusal wraps `small)` onto a
  second row, and Oh My Pi draws its session title, dim and italic, between
  it and the status band.
- Oh My Pi used the nerd-font status band.
- Captures are 119, 120, 62 or 40 columns wide; Pi's are 119 unless the
  name or the note above says otherwise, Oh My Pi's 120.
- The shell rows of `pi-03`, `pi-06`, `omp-21` and `omp-33` keep the probe's
  `SOCK=`/`HOME=` echo and the shell prompt.

Scrubbing replaced the account name as above and the shell prompt's
`user@host` with `developer@probe-host-placeholder-01`, both with
replacements of the same length. These screens are not part of
`ScreenFixture.all`, which the dialog and input-box suites walk.

### Core paints

`screens/core-paint/*.paint` are the first paint of an observing attach from
herdr-core 0.1.13 through `scripts/fixtures/herdr-core-ssh.py` on 2026-10-31,
with no harness signed in: an inert program replayed the `.ansi` screen of the
same name in a core Terminal at that screen's size. So the screen drawn is the
earlier capture's, and the bytes around it are the core's. `modes-*` are not
replays: the program set the alternate screen, bracketed paste, kitty flags 9
and application cursor keys, or nothing. These are provisional until a live
Agent on a core is captured.

### Grok Build screens

`screens/grok/grok-*.ansi` are visible-screen reads from Grok Build 1.0.62 on
herdr 0.9.5 (2026-10-19), kept as herdr returned them apart from the
scrubbing below: CRLF rows, SGR styling only. Two Agents ran in scratch
projects under the developer's account, `cap-grok-a` and `cap-grok-b`; every
screen is 47 rows of 181 or 182 columns, except `grok-28` to `grok-45` (below).
Screens whose header shows
`/U/d/s/cap-grok-a/proj` ran with `HOME` pointed at a scratch directory, where
Grok asks before running a tool; the developer's own settings put it in
Auto-review, which draws no permission card. The model answered the scratch
prompts in Chinese, and its replies stay as captured.

| Fixtures | Captures |
|---|---|
| `grok-01-idle-empty`, `grok-02-idle-draft`, `grok-03-working` | `A11a-idle-empty`, `A11b-idle-draft`, `A8b-running` |
| `grok-04-working-draft`, `grok-05-queued`, `grok-06-esc-toast` | `A9c-working-draft`; `A10-queued`, a follow-up `agent.prompt` queued during a turn; `A8b-after-esc-0.4s`, the toast Esc shows while the turn goes on |
| `grok-07-slash-popup`, `grok-08-at-popup`, `grok-09-model-picker` | `A11c-slash-popup`, `A11d-at-popup`, `X17-model-picker` |
| `grok-10-btw`, `grok-11-dashboard` | `X12-after-4s`, a `/btw` aside answering in a box above the composer; `X14-dashboard` |
| `grok-12-permission-command`, `grok-13-permission-compound`, `grok-14-permission-edit` | `A4j-blocked`, `A5-blocked`, `A6a-blocked` |
| `grok-15-question`, `grok-16-subagent-panel` | `cap-grok-b`'s `B9-question`; `cap-grok-b`'s `X8-after-ctrlc-subagent`, the question Ctrl+C asks while a subagent runs |
| `grok-17-session-new`, `grok-18-session-fork`, `grok-19-resumed-other` | `cap-grok-b`'s `B2-after-new` and `X2-after-fork-no`; `X6-after-resume` |
| `grok-20-welcome`, `grok-21-resume-picker`, `grok-22-rewind-picker` | `A1-after-start`; `cap-grok-b`'s `B5-picker`; `X8-picker` |
| `grok-23-rewind-confirm`, `grok-24-restored-draft`, `grok-25-fork-question` | `X8-after-enter`; `X1-after-early-ctrlc-2s`, a prompt Ctrl+C stopped before any output, put back in the box; `cap-grok-b`'s `X2-after-fork`, the worktree question `/fork` asks |
| `grok-26-waiting-subagent`, `grok-27-compacting` | `cap-grok-b`'s `B7-t6s`; `A12-t+1s`, a `/compact` a second in |
| `grok-28-welcome-62`, `grok-29-welcome-40` | The Welcome screen at the phone's 62×41 grid and at 40×30, where Grok draws its menu without the box |
| `grok-30-idle-62x20`, `grok-31-scrollback-62x20`, `grok-32-working-62x20`, `grok-33-working-scrollback-62x20` | The phone's 62×20 grid with the keyboard up, where Grok forces compact mode: idle, then the scrollback focused with Tab; a `sleep 15` turn running, then the scrollback focused |
| `grok-34-working-draft-62` | The phone's 62×41 grid: a `sleep 60` turn running with `draft text` typed in the terminal, whose footer stops at `Enter:queue │ Shift+Enter/Opt+Enter:newline │` |
| `grok-35-permission-subagent-62` | The phone's 62×41 grid: the card Grok asks before a subagent starts, `Allow Sleep 60 then reply done?`, its always-approve row cut at the card's edge |
| `grok-36-permission-command-40`, `grok-37-permission-command-62` | A command's card at 40×30, where Grok cut the rule to `Always allow: chmod 644…` and the description with `…` (derived, below); the same card at the phone's 62×41 grid, where both read in full |
| `grok-38-fork-question-62`, `grok-39-fork-question-40` | The worktree question `/fork` asks, at the phone's 62×41 grid with every row in view, and at 40×30, where the card scrolls all but `1` and `z` out of view |
| `grok-40-agent-view-other-62`, `grok-41-agent-view-this-62`, `grok-42-agent-view-dispatched-62` | The dashboard's view of an agent at the phone's 62×41 grid, its footer cut at `Ctrl+x:`: another session opened from the dashboard while herdr reported the first; the first after `/resume` back to it, which kept the view; the first again after Esc from a dispatch that moved herdr to the new agent |
| `grok-43-resumed-from-welcome-120` | At 120×40, the session a `/resume` typed on the Welcome screen put on screen, its newest message one Chat sent there, while herdr reported the empty session the typed command started first |
| `grok-44-permission-second-subagent-120` | At 120×40, the second of two spawn cards for parallel subagents with one description, `Allow Sleep 90 then done?`, read 2.6 s after `2` approved the first, while its subagent ran and herdr stayed Blocked: only the status row's timers differ from the first card |
| `grok-45-compaction-cancelled-62` | The phone's 62×41 grid after Chat's Stop cancelled a `/compact` (2026-10-22): `Compaction cancelled.` under the `Compacting conversation…` row, with only blank rows and the scrollbar's thumb between it and the box. Grok writes no record for it |

Captures not marked `cap-grok-b` come from `cap-grok-a`, except `grok-28` to
`grok-45`, which come from later Agents (2026-10-20 and 22) in the scratch project
`/tmp/hcl/proj-grok`, with nothing to scrub. They are kept as read, except
`grok-36-permission-command-40`, which is derived, not captured: that read
took the pane's ANSI a moment before Grok drew the card and its text just
after, so the fixture keeps every character and column of the text read and
takes its styles from `grok-37`, the same card read at 62×41 a minute later,
and from the 40×30 ANSI read for the header and the pinned prompt. Blank rows
take the backgrounds those reads show, the scrollbar's track and thumb
included. Replace it with a capture when one is taken.

Scrubbing replaced the account name with `developer` and the scratch
directory the probes ran in with `/Users/developer/scratch/`; the header's
abbreviated forms follow (`/U/d/s/cap-grok-a/proj`, `~/s/cap-grok-b/proj`).
These paths are shorter than captured, so the next run of two or more spaces
after each, or the row's trailing spaces, takes up the difference: borders
and right-aligned text keep their columns. The `Session <id>` lines carry
synthetic ids from the range the Grok transcript fixtures use. In `grok-15`,
the question and options the model wrote in Chinese became the English of
`grok/subagent-todo-question.jsonl`, in the card and in the rows above it.
Grok pads option labels by characters, not cells, so the two descriptions
start two columns apart, as captured, where Grok would line up English
labels.

The tests also build synthetic screens, labelled synthetic, for states and
widths no capture shows yet: `Support/GrokScreenBuilder.swift` lays rows out
the way Grok's source does (the turn status row cut to fit, dock rows, the
composer box, a footer whose hints stop at the right edge), and
`ScreenFixture.synthetic` takes raw rows. They cover the 40- and 62-column
working, queued and subagent-wait screens with cut footers, the other waits
that a message would cancel, parked turns, footers that show another pane
has focus, ghost text, Bash and Remember modes, `/multiline`, editing a
queued message, a pending double press, and minimal mode. Replace each with
a capture when one is taken. These screens are not part of
`ScreenFixture.all` either.

### OpenCode screens

`screens/opencode/opencode-*.ansi` are visible-screen reads of OpenCode
2.0.32 on herdr 0.9.5, with scratch prompts. Stems keep their capture
numbers, so the numbers have gaps.

- `opencode-01` to `opencode-21`, `opencode-23`, `opencode-24` and
  `opencode-26` come from the sessions of the stores below, through 180×47
  clients on 2026-10-19; their rows are 182 cells wide (181 in
  `opencode-01`).
- `opencode-22`, `opencode-25` and the `-62` stems come from an isolated
  herdr server on 2026-10-20, in a scratch project under `/tmp`. A client of
  the named width attached and detached before each read, so the pane kept
  its size; `opencode-22` and `opencode-25` are 180×47 and the `-62` stems
  62×41. `opencode-25` and `opencode-42` show the `Reject permission` stage:
  OpenCode's default ask rule for `*.env` reads stopped a subagent reading a
  scratch `.env` file, and Esc in the terminal opened the stage. The scratch
  project had no `.opencode` config.
- `opencode-27`, `-28` and `-29` are derived, not captured: OpenCode
  2.0.32's permission for a shell command, which no capture shows, rebuilt
  at 180×47 from stem 10's rows and colors and the permission component in
  OpenCode's bundle. A shell command's permission has no action row under
  `△ Permission required`, only its `$ git status` line in the text color;
  with Always allow focused (`opencode-28`) that line gives way to the
  rule's, `This will always allow the following patterns for this
  project.` and `- git status *`, a blank row apart. `opencode-29` is the
  next command's permission, `rm -rf build`. Above them are stem 10's
  earlier rows, a scratch prompt asking for both commands, and the two
  calls running, the one whose permission shows in the warning color. A
  script outside the repository derives them. Replace them with captures
  when they are taken.

Scrubbing applied the stores' path, account and placeholder rules to every
byte. Assistant text in Chinese became English no wider than it, with blanks
added at the end of its row, so every row keeps its captured width. The
`/tmp` stems keep that scratch project's path, whole or shortened. The checks
under the stores' scrubbing cover `screens/opencode/` as well. Together the
files are about 570 KB. These screens are not part of `ScreenFixture.all`
either.

## OpenCode stores

`opencode/` holds OpenCode session stores for the store query tests
(ADR 0025). They come from OpenCode 2.0.32 sessions on herdr 0.9.5, captured
on 2026-10-19 and 2026-10-20 in scratch projects with scratch prompts. None
came from a personal session.

- `schema.sql` is the DDL of the four tables the query reads (`session_v2`,
  `session_message`, `event_sequence` and `session_inbox`), with OpenCode
  2.0.32's column order, types and indexes, the unique `(session_id, seq)`
  index included. Foreign keys are left out.
- `store-<scenario>.json` is one store: `session`, `event_seq`, `rows` and
  `inbox` as the tables hold them, JSON columns as compact JSON text, and
  `otherSessions` for further sessions in the same database.
  `Support/OpenCodeSQLiteHarness.swift` builds an SQLite database from one.
- `rows-<scenario>.jsonl` is what the query prints for that store's tail with
  a 512 KiB budget: the session line, the inbox line, then the rows oldest
  first.

| Scenario | Source |
|---|---|
| `pong` | A one-word reply |
| `approve`, `reject` | A `read` permission approved, then the same read declined |
| `esc-stop` | A shell command stopped with Esc |
| `patch` | Two `patch` calls: a file added, then edited |
| `compact` | `/compact` and its summary |
| `steer`, `steer-queued` | A message sent while a shell command ran. `steer` is the finished exchange. `steer-queued` is derived, not captured: the store when the message was sent, rebuilt from the session's poll log, with the shell call still running and the message waiting in the inbox |
| `subagent` | A `subagent` call; its child session is under `otherSessions` |
| `question-blocked`, `question-answered` | A `question` call waiting for its answer, then answered. The waiting store takes its rows from a dump taken while the call waited and their ids and creation times from the answered dump; its event counter (111) is set between the two dumps' |
| `undo-before`, `undo-staged`, `undo-committed` | `/undo` in a second session: before it, with the revert staged, and after the next prompt committed it |
| `two-sessions` | Written for the tests: a second session in the same store, with its own rows and inbox, which no query may read |
| `v1-names` | Written for the tests: OpenCode 1.x tool names (`bash`, `task`, `apply_patch`, `todowrite`, `edit`) and their `diff`, `filediff` and `files` metadata |
| `odd-types` | Written for the tests: a string tool error and input, numeric times, an attached file, content parts with an unknown type or none, and an inbox item whose text is a number and whose files are a string |
| `row-types` | Written for the tests: rows of the other types (`shell`, `synthetic`, `system`, `skill`, `location-switched` and `model-switched`), an unknown type, a running shell command, compaction and assistant row, and an assistant row of the wrong shape |

The tests build three stores in place rather than from files: one with
OpenCode 1.x tables only, a staged revert carrying 3 MiB of patch text, and
an inbox of 20 long items.

Together the files are about 116 KB: 71 KB of stores, 42 KB of rows and the
schema.

### Scrubbing

A script outside the repository derived the stores from the captures, in
this order:

1. The scratch project paths became `work/heeler-tmp-chat/opencode-a/project`
   and `work/heeler-tmp-chat/opencode-b/project`, the account name
   `developer`, and the capture's job directory, scratch directory names and
   host name same-length placeholders.
2. `ses_`, `msg_`, `prt_` and `sh_` ids became synthetic ids of the same
   shape (12 hex digits, then 14 base62 characters), consistently across a
   scenario's stores; the session under test is
   `ses_0a1b2c3d4e5fK2mN8pQ4rT6vX9` in each. `call_` ids became `call_` and
   24 base62 characters, and project ids hashes of fixed strings.
3. Assistant text in Chinese became English, the compaction summary
   included. User text is the scratch prompts only.
4. `providerState`, `providerResultState`, `itemId`,
   `reasoningEncryptedContent`, `responseId`, `snapshot`, `files[].data` and
   `metadata.diagnostics` were dropped.
5. Times moved so each scenario's earliest is `1800000000000`, keeping the
   gaps between them. Model names, token counts and costs are as captured.

Before committing a change here, check that searching `opencode/` finds none
of the account, host or scratch directory names, no `/Users/` other than
`/Users/developer`, no `ghp_`, `Bearer`, `sk-` keys or e-mail addresses, no
CJK text, and none of the real ids the script replaced (it lists them in a
file outside the repository).

### Regenerating the rows

`OpenCodeStoreQueryTests/rowFixturesMatchTheProbeOutput()` fails when the
query's output drifts from `rows-*.jsonl`. After an intended change, run that
test with `HEELER_WRITE_OPENCODE_ROWS` naming a directory outside the
repository (`TEST_RUNNER_HEELER_WRITE_OPENCODE_ROWS` through `xcodebuild`):
it writes the files there instead of comparing. Review them, copy them in,
and run the test again. It compares parsed JSON, since SQLite versions may
escape text differently.
