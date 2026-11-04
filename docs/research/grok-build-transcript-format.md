# Grok Build transcript and screen observations

Versioned observations:

- Grok Build 1.0.62 (macOS arm64), live on scratch panes against herdr 0.9.5
  on 2026-10-19: `agent.get`, pane reads (plain and ANSI), the new
  `updates.jsonl` lines polled every 50–100 ms, and the user guide that ships
  with the build (`~/.grok/docs/user-guide/`).
- Grok Build 1.0.62 checked on 2026-10-20, marked "(live, 2026-10-20)": an
  isolated herdr 0.9.5 server and `sshd`, the app on an iPhone 17 Pro
  Simulator, scratch projects and scratch prompts, with keys and prompts
  sent through the app or herdr's CLI (`agent prompt`, `agent send-keys`,
  `pane send-text` and `pane send-keys`). The app sized the pane to 62×41
  cells (62×20 with the keyboard up), a pty-attached `herdr agent attach`
  sized it to 40×30 or 120×40 for some captures, and a pane the app had
  not attached was 120×40 (Grok's start) or 119×40 (the long-path
  session). herdr's status was polled about every 0.13 s and the screen
  about every 0.14 s; for part of the run, the sizes of the folder's
  `prompt_history.jsonl` and of each session's `updates.jsonl` were polled
  every 20 ms.
- Grok Build 1.0.45 source,
  [`xai-org/grok-build` at `2bdd1d6a`](https://github.com/xai-org/grok-build/tree/2bdd1d6a6369de0e8c68132ea4539e9abd9e14a8/crates/codegen).
  Source paths below are under `crates/codegen/`, in `xai-grok-pager/src`
  unless a crate is named. The source predates the installed build, so a
  claim that rests on it alone says so.
- A structure-only census of one Host's `~/.grok/sessions` (406 sessions in
  185 folders, 216,425 records, written by builds from 2026-08 to 2026-10):
  keys, types, short enum values, counts and sizes, never text.
- herdr 0.9.5 source: the Grok hook asset (integration version 3),
  `src/agent_resume.rs`, `src/terminal/state.rs` and the `grok.toml`
  detection manifest (2026.10.05.1). The herdr facts are also in the
  [compatibility notes](../agents/herdr-compatibility.md).

## Identity and location

herdr's Grok integration installs a SessionStart hook that reports
`{source: "herdr:grok", agent: "grok", kind: "id", value}`, never a path.
The value is the session id: a lowercase UUIDv7 (all 406 census sessions)
that names the session folder and equals every record's `params.sessionId`.
Grok mints these ids, but `grok -s` accepts one chosen by the caller (user
guide `17-sessions.md`). At start, the session folder appears first,
`updates.jsonl` 100–300 ms later with herdr's `session_start` hook record,
and herdr reported the id 60–110 ms after that record, before any prompt.

herdr replaces a Grok Agent's session only when SessionStart's `source` is
`new`, or when the pane has none yet; it normalises Grok's `load` away
(herdr 0.9.5 `normalize_session_start_source`). Live, unless marked:

- `/new` and `/clear` start a new folder in the same group, adopted within
  about 0.1 s of its first record. The earlier session stays open in the
  process, its file untouched, and the screen prints `Session <id>, use
  /dashboard to switch between sessions`.
- `/resume` to a session already open in the process writes nothing
  anywhere. herdr keeps the old id, and the next prompt lands in the resumed
  file. `/resume` to a closed session appends `background_tasks{tasks: []}`
  and a `session_start` hook record (source `load`) to that file, which
  herdr ignores.
- `/fork` first asks, on a Blocked card, whether to use a worktree. Either
  answer creates a session holding a copy of the parent's records, and
  herdr keeps the parent. The screen prints `Session <id> (forked from
  <parent>), use /dashboard to switch between sessions`, with `(both agents
  share cwd)` on the next row when no worktree was made. The copy was
  followed by `background_tasks` and a `hook_execution` record (live,
  2026-10-20). `/resume` back to the parent showed `Forked` as its newest
  row and no Session line in three captures (live, 2026-10-20), as the
  1.0.45 source has it: Grok prints a Session line only into the scrollback
  of the session it names (`dispatch/session/lifecycle.rs`, `load.rs`), and
  each agent keeps its own scrollback.
- A message sent while the dashboard shows dispatches a new agent, which
  herdr adopts (`new`) while the screen still shows the dashboard. Esc back
  to the earlier session leaves herdr on the new agent. One dispatch was
  adopted 0.45 s after Enter and reported idle throughout its turn (live,
  2026-10-20). Peeking at a session from the dashboard, opening it there,
  and leaving the dashboard leave herdr's report unchanged (live,
  2026-10-20).
- `grok --resume <id>` and `grok --continue` in a pane with no reported
  session are adopted, because the pane has no id. herdr reported such a
  restart `unknown` with no session, then `unknown` and idle on that id
  (live, 2026-10-20).
- `/quit` clears `agent_session` and the Agent's status. Grok prints
  `Resume this session with:` and `grok --resume <id>` for the session on
  screen, which need not be the one herdr reports (live, 2026-10-20). In
  the dashboard's agent view, `/quit` instead closed that session, wrote no
  record and showed the dashboard, and herdr's report did not change; Esc
  and Ctrl+Q twice then quit Grok, and herdr reported idle with no session,
  then no Agent (live, 2026-10-20).
- `/home` (alias `/welcome`) leaves the session for the Welcome screen, by
  the user guide. Pasted on macOS, `/home ` named an existing path: Grok put
  the resolved path (`/System/Volumes/Data/home`) in its box and sent it to
  the model as a prompt. `/welcome ` opened the Welcome screen, and herdr
  kept the session (live, 2026-10-20).
- Text sent from that Welcome screen, while herdr reported a session with
  messages, first started a new session in the same group (live,
  2026-10-20). For `Reply with the word lemon`, the folder appeared, then
  herdr's hook record 0.22 s later, the `prompt_history.jsonl` line and the
  user record (`promptIndex` 0), and the screen showed the new Session line
  while the text was still in the box. The message ran in the new session
  (its user record and `prompt_history.jsonl` line name it), and herdr's
  report, polled about every 0.13 s, showed that session within 107 ms of
  the hook record; the user record came 84 ms after the hook record, 23 ms
  before that report. A `/resume <id>` sent there also started a new session,
  holding only the hook record, which herdr's report showed within 62 ms
  of that record and kept, while the resume put the other session on
  screen. The Welcome screen's own resume picker (Ctrl+R, then Enter)
  started no session. By the 1.0.45 source
  (`dispatch/session/lifecycle.rs`), a send from the Welcome screen first
  runs `leave_welcome_for_session`, which switches to the home session
  Grok created in the background at start, if one is still unused, and
  otherwise calls `dispatch_new_session`; the input runs after that. So
  whatever is typed there, a command included, starts a session herdr
  adopts, and after a typed `/resume` herdr keeps that empty session, as it
  never follows `/resume`, while the screen shows the resumed one; the
  picker is the way back that starts none. At Grok's start, the first
  message went to the session herdr already reported (two captures, live,
  2026-10-20).

The two `Session` lines sit outside any box at the scrollback's
five-column indent, and a pane narrower than the line wraps it: `/new`'s
took two rows at 62 columns and four at 40, and `/fork`'s three at 62 and
five at 40, with `(both agents share cwd)` on the next row two columns
further in (live, 2026-10-20). At 40 columns the id can break after one of
its `-`, and at both widths a row can end in `use /` with `dashboard` on
the next. When Grok resumes a session it finds under another directory, it
also prints `Session <id> found locally (originally in <dir>)` on standard
error at start (source: `app/session_startup.rs`).

Sessions live in `<GROK_HOME>/sessions/<group>/<id>/`, where `GROK_HOME`
defaults to `~/.grok` (`xai-dirs` `grok_home`). The variable lives in the
Grok process's environment, which herdr does not report, so a custom root
can't be found from the Agent's report. The group is the session's working
directory with every UTF-8 byte outside `A-Z a-z 0-9 - _ . ~` written as
uppercase `%XX` (`xai-grok-config/src/paths.rs` `encode_cwd_dirname`):
`/home/dev/My Project` becomes `%2Fhome%2Fdev%2FMy%20Project`. All 406
census sessions match. Grok takes the directory from `getcwd`, so a session
started in a symlinked directory files under the physical path, which is
also what herdr's `cwd` and `foreground_cwd` report.

A name longer than 255 bytes becomes `<slug>-<16 hex>` instead. The slug is
the path's last component lowercased, with every run of characters other
than ASCII letters and digits turned into one `-`, trimmed of `-` at both
ends and then cut to 40 characters, so a cut can end on `-` (`workspace`
when empty); the hex is the start of the BLAKE3 hash of the path's bytes.
The group then holds a `.cwd` file with the raw path bytes and no newline,
created exclusively. No census group was that long. Live (2026-10-20), a
session started in a 220-byte physical directory (212 bytes as typed, 266
encoded) whose last component is `Projet Café Grok 长路径 test` was filed
under `projet-caf-grok-test-<16 hex>`, with a 220-byte `.cwd` equal to the
physical path. That group keeps its own `prompt_history.jsonl`, whose first
line named the session, and Chat found the session there.

herdr's directory is not always the session's. `/fork` into a worktree,
and `/new` inside that worktree session, file the session under the group
of the worktree's path (which lies under `~/.grok/worktrees/`), while herdr's
`cwd` and `foreground_cwd` keep naming the pane's directory; herdr adopted
the `/new` session's id all the same. Finding such a session takes a
search of other groups for `<id>/updates.jsonl`. A session folder can exist
without `updates.jsonl` for 100–300 ms, and 2 of the 406 census sessions
never got one. The file's first record names the session in `"sessionId"`
within about 110 bytes. A fork's copied records carry the fork's
`sessionId` but keep the parent's `eventId` prefix.

Each session folder also holds `summary.json`, `chat_history.jsonl` (the
model's context, not a display source), `events.jsonl`,
`rewind_points.jsonl` and more; a subagent gets a sibling session folder in
the same group. The group itself holds `prompt_history.jsonl`. For every
submitted prompt, any Grok process working in that directory appends
`{prompt, is_bash, session_id, timestamp}` just before it writes the user
record, with the prompt trimmed (unlike `updates.jsonl`). A prompt queued
while Grok works gets its line when it is submitted, not when it is
queued; commands such as `/new` and `/compact` add none. Live
(2026-10-20), the line came 6–14 ms before the user record in eleven sends,
named the session on screen even when herdr reported another, and
`/compact`, `/fork` and `/resume` added none. Grok keeps at most 10,000
entries and may rewrite the file through a temporary file and a rename when
it installs a session (source: `xai-grok-shell` `session/prompt_history.rs`).
`~/.grok/active_sessions.json` lists every open session on the machine
(`{session_id, pid, pid_start, cwd, opened_at}`), but not which one a
process shows.

## Records and turns

Each `updates.jsonl` line is `{timestamp, method, params{sessionId,
update{sessionUpdate, …}, _meta}}`. `timestamp` is whole seconds;
`_meta.agentTimestampMs` is milliseconds and, for a merged block, the time
it was flushed (`turnStartMs` and `streamStartMs` give the stream's times).
`method` is `session/update` for ACP kinds and `_x.ai/session/update` for
Grok's own. `_meta.eventId` is `<sessionId>-<n>` from a counter shared by
the whole process, and it is not a key: a fork's copied records keep the
parent's prefix, and the census found 92 reused after one rewind by an older
build. Agent records carry `_meta.promptId`; user records don't. New builds
add kinds and keys.

Grok holds the newest ACP record in memory, merges consecutive message or
thought chunks into it, and writes it when the next ACP record arrives or
the turn ends (`xai-grok-shell` `session/persistence.rs`). Its own records
are written at once and can overtake it: a spawn's `subagent_spawned` and
`subagent_finished` landed before the spawn's input update. So message and
thought chunks are whole blocks on disk, a turn's last text appears with its
`turn_completed`, and while a command runs the file shows only its
`tool_call` (for 40 s with `sleep 40`). Every capture flushed the held record
before `turn_completed`. Appends take a lock and write whole lines with
`O_APPEND`; the file is rewritten whole only on a session import or a remote
pull (source). Live, it stayed append-only through restarts, `/compact`,
`/rewind`, `/new` and `/resume`. A user record reached disk 343–496 ms after
`agent.prompt` started, herdr's 300 ms Enter delay included.

`user_message_chunk` holds `content{type, text, _meta?}` and
`update._meta{modelId, promptIndex?, hideFromScrollback?}`:

- One prompt content block is one chunk. A prompt of several blocks is
  consecutive chunks with consecutive event numbers and one `timestamp`.
- The text is recorded byte for byte, Heeler's trailing space included,
  except a skill's (below) and a pasted `/home `, which Grok sent and
  recorded as the resolved path `/System/Volumes/Data/home ` (live,
  2026-10-20). Multi-line pastes and an 11,262-byte paste were recorded
  whole.
- `promptIndex` counts submitted prompts from 0. A chunk without one is an
  interjection in the running turn (steer mode; census and source only) or a
  shell-mode record.
- `hideFromScrollback` marks a turn Grok started itself, after a task,
  subagent or notification; its text starts with a tag such as
  `<system-reminder>`.
- A skill records `content._meta.displayAsSkill` and `displayText`
  (`/name args`). In 1.0.62 the chunk's text was `/name args` as well, not
  the skill's body, and without Heeler's trailing space: `/heeler-probe
  alpha beta ` was recorded as `/heeler-probe alpha beta` (live,
  2026-10-20).
- `!cmd` typed in Grok records `content._meta.bash_command`, then a command
  call whose id is `bash-mode-<uuid>`.
- Image blocks are possible (source) but none were seen; `image_dropped`
  and `image_compressed` are Grok's notices about them.
- A `read_file` of an image names the file only in its call
  (`rawInput.target_file`) and input update (`locations[].path`); the result
  holds the image as a `content` block `{type: "image", data, mimeType}` and
  as `rawOutput{type: "ReadFile", ImageContent{data, mime_type}}`, with no
  path. A text read's `rawOutput` holds `FileContent` instead. (Grok Build
  1.0.70, live on 2026-11-02; a local session from 2026-08-27 had the same
  shape.)

A chunk with a `promptIndex` opens a turn, and `turn_completed{prompt_id,
stop_reason, agent_result?, error_kind?, usage, elapsed_ms?}` closes it. The
census has `stop_reason` `end_turn` 941 times, `cancelled` 47 and `error`
once. A cancel's `params._meta` carries:

- `cancelTrigger`: `ctrl_c`, `send_now` or `shutdown`, plus `esc` in
  builds until early September 2026; the source adds `mouse` and
  `dashboard_stop`.
- `cancellationCategory`: `MidTurnAbort`, or `PermissionRejected` with
  `cancellationContext{tool_name, reason}` and no trigger after a reject.
  Ctrl+C on a permission card gives `PermissionCancelled`, also with no
  trigger (live, 2026-10-20). The source gives `HookDenied` for a hook; the
  1.0.62 binary also holds `HookStopped`, so that spelling is unverified.

A cancelled turn keeps its usage. Neither 1.0.62 cancel captured with
records on 2026-10-19 (Ctrl+C during a command, and a reject) wrote a final
message, and a call still running at the cancel never gets a final update.
A reject writes the failed result of the call it refused (below), and so
did Ctrl+C on a permission card: `User cancelled the execution for tool …`
with `_meta.toolNotRun: cancelled`, 69 ms before the `turn_completed`
(live, 2026-10-20). Thought, message and tool records can follow a
`turn_completed`, and some completions name no prompt (census). Hook
records (`hook_execution`) exist only for configured hooks: herdr's
SessionStart hook, and hooks from the user's settings, such as the Claude
Code hooks Grok imports from `~/.claude/settings.json`. They never mark
turns.

Ctrl+C before the first output is a cancel-rewind. Grok drops the prompt
from its conversation, puts the text back in its input box, and writes no
`turn_completed` and no marker, but the user chunk stays on disk. The next
prompt reuses its `promptIndex`, and because the text sits in the box, a
paste joins it: Grok recorded `Reply with the word kiwi.Reply with the word
lime.` as one chunk. All 7 census prompts that reuse the previous
`promptIndex` follow a prompt with no output and no `turn_completed`.

`/rewind` (alias `/undo`), or Esc twice on an empty idle box, opens the
picker `Rewind to which turn?`; its confirmation card (`y`, `a`, `n`) is
Blocked. A rewind appends `rewind_marker{target_prompt_index, created_at}`
and rewrites nothing in `updates.jsonl` (it rewrites `chat_history.jsonl`
and `rewind_points.jsonl`), shows `Reverted conversation`, and restores the
rewound prompt as a draft that the next paste joins. Every record from the
first chunk whose `promptIndex` is at or above the target, up to the
marker, is gone from the conversation. Grok's replay counts user runs
instead (`xai-grok-shell` `session/storage/mod.rs` `filter_rewind_by`); the
two agree on every capture. Event numbers kept rising after the 1.0.62
rewinds. The census's one rewind, by an August build, wrote no marker, only
a drop in `promptIndex`.

`/compact` writes no user chunk and no `turn_completed`. About 8 s after the
send come `compaction_checkpoint{checkpoint_id, prompt_index_at_compaction,
checkpoint_file, schema_version: 1, created_at}` and
`auto_compact_completed{tokens_before, tokens_after, summary_preview: null}`,
without the `elapsed_ms` key the source writes as null. In a later capture
they came 16 s after the send, while the screen showed `Compacting
conversation…` and then `Compaction completed in 16s.` (live, 2026-10-20).
Automatic compaction writes `auto_compact_started{reason, tokens_used,
context_window, percentage}`, the checkpoint and `auto_compact_completed` in
mid-turn, and a cancelled one writes `auto_compact_cancelled` (source).
A `/compact` that Ctrl+C cancelled while the screen showed `⠼ Compacting…`
wrote nothing at all; the screen added `Compaction cancelled.` under
`Compacting conversation…`, and herdr went back to `idle` (live,
2026-10-22). Chat reads the screen for that row once such a `/compact` is
overdue. Nothing above a compaction is rewritten, and `summary_preview` was
always null.

Live (2026-10-20), one turn that read 21 files of 99,000 bytes each
compacted automatically three times. Each `auto_compact_started` was
followed 8–15 s later by the checkpoint and `auto_compact_completed`,
written within 1 ms of each other, and after the third came
`auto_compact_failed{error}`, whose text said the context had refilled to
the limit right after each of the last three compactions and that automatic
compaction was off for the rest of the turn. The turn still ended
`end_turn`, after 136 s. A whole file's `read_file` result line was about
402 KB, so `updates.jsonl` grew from 62 KB to 34.2 MB in that one turn.

`/compact` takes no focus: with text after it, Grok shows the toast
`/compact takes no arguments.`, keeps the text in its box and writes
nothing. In a session with no messages it compacts anyway; one such run
took 1m37s and wrote the checkpoint and `auto_compact_completed` (live,
2026-10-20).

Each `toolCallId` writes three records:

1. `tool_call`, whose `title` is the tool name, with a partial `rawInput`
   and `_meta["x.ai/tool"]{name, kind, label, namespace, read_only,
   version}`;
2. the input update, which Grok holds back: `kind`, a human `title`,
   `locations`, `rawInput{variant, …}`, and a `diff` preview for edits;
3. the result: `status` `completed` or `failed`, `content`, `rawOutput`, and
   in 1.0.62 `_meta.toolNotRun` (`rejected` or `cancelled`) for a call that
   never ran.

While a card waits, only the first is on disk. It already holds what the
card names: `rawInput{command, description}` for `run_terminal_command`,
`{file_path, old_string, new_string}` for `search_replace`, and
`questions[{question, options[{label, description}]}]` for
`ask_user_question` (`multiSelect` comes only in the update). An approval
writes nothing. A reject writes the failed result `User rejected the
execution for tool …` and ends the whole turn (`PermissionRejected`).

- Edit results carry `content[{type: diff, path, oldText, newText,
  _meta.details[{old_line, new_line, old_string, new_string,
  context_before, context_after, line_prefix}]}]` and `rawOutput{type:
  SearchReplace, EditsApplied{…}}`; the input update's preview has
  `_meta{old_line, new_line}`, and a created file has no `oldText`.
- Command results keep `output_for_prompt` beside the byte arrays `output`,
  `stdout` and `stderr`. The result's text and `output_for_prompt`, which
  starts with the exit status (`exit: 0`), both end with the output's last
  line break (live, 2026-10-20).
- Failures are `{error: tool_execution_failed, message}`, or a tagged
  variant such as `FileNotFound`, `MultipleMatchesFound`, `InvalidInput`,
  `IsADirectory` or `FileTooLarge`.
- `todo_write` is followed by a `plan{entries}` snapshot of the whole list.
- A question's result text reads `User has answered your questions:
  "<question>"="<label>"`. A skipped or timed-out question (30 minutes by
  default) completes with an "unanswered" message, and the turn goes on
  (source).

`spawn_subagent` (`rawInput{description, prompt, background}`) is followed
by `subagent_spawned{subagent_id, attempt_id, parent_session_id,
parent_prompt_id, child_session_id, subagent_type, description,
effective_context_source, model}` and `subagent_finished{subagent_id,
status, tool_calls, turns, duration_ms, tokens_used, output, will_wake,
error?}`, both of which can land before the spawn's held input update. The
child is a sibling session folder (`session_kind: subagent`) with no
`session_start` and no herdr report. When the parent turn is cancelled, its
`turn_completed` comes before the child's `subagent_finished{status:
cancelled, error: "Subagent was cancelled"}`, and the spawn call never gets
a final update. A backgrounded command writes `task_backgrounded{task_id,
tool_call_id, command, cwd, description, output_file}` and later
`task_completed{task_snapshot{…, exit_code, signal, kind}, will_wake}`;
`will_wake: true` comes before a turn Grok starts itself.

Errors rest on the source and the census. One `retry_state` came live,
between a user record and the reply of a turn that ended `end_turn`; its
variant was not noted (live, 2026-10-20). `retry_state` is
`retrying{attempt, max_retries, reason, error_type?}` between records (73 in
the census, none ending a turn), or `exhausted{attempts, reason,
is_rate_limited}` and `failed{error_type, message}`. An error turn ends with
`turn_completed{stop_reason: error, agent_result, error_kind?}`, where
`agent_result` is the error text and `error_kind` the sampler's kind
(`auth`, `http`, `api`, `rate_limited`, `idle_timeout` and others).
`session_recap{auto, summary}` after a `turn_completed` is a summary, not a
turn. `response_started`, `turn_usage`, `model_changed`, `served_model`,
`available_commands_update` and `current_mode_update` never reached disk in
1.0.62.

## Screen, input and keys

Grok's input box is the bottom-most rounded box: a `╭─` top border, rows
starting `│ ❯ `, and a `╰─` bottom border that carries the model label
(`Grok 4.7 Fast (high)`). A typed `!` on an empty box enters Bash mode
(`│ ! `, with the placeholder `Run shell command`), and a typed `#` enters
Remember mode (`│ # `) only with `[features] remember_mode`. `/multiline`
turns its mode on or off with the toast `✓ Multiline: on` or `✓ Multiline:
off`. While it is on, the bottom border adds `─multiline ─` after the model
label (`… Grok 4.7 Fast (high) ─multiline ─╯` at 62 and 120 columns,
`╰─ Grok 4.7 Fast (high)─multiline ─╯` at 40), and with `/multiline` typed
in the box and its popup open, the footer started `Shift+Enter:send` at 120
columns (live, 2026-10-20). While a queued message is edited, the bottom
border reads `editing queued #N` in the model label's place (live,
2026-10-20). The top border can carry a label such as `Stashed` or a
`/rename` title (source). The agent view draws no placeholder while the
prompt has focus; without focus an empty box reads `❯ Build anything`
(live, 2026-10-20), and the dashboard's box reads
`❯ Dispatch a new agent`. A paste of 4 or more lines, or over 10,000
bytes, shows as a chip that still holds the whole text. Minimal mode draws
no box at all (below).

Grok draws ghost text, shell completions and prompt suggestions after a
turn, dim and italic by the source (`xai-grok-pager-render/src/theme/mod.rs`
`ghost_text_style`); typed text is never italic. The one suggestion
captured live, on an idle, empty box at 62×41, was italic (SGR 3) in grey
(88, 88, 88) without the dim attribute, under the footer `Tab/→:accept
suggestion │ Shift+Tab:mode │ Ctrl+.:` cut at the pane's edge, and a
message pasted over it was sent (live, 2026-10-20). On an empty box the
ghost is the whole suggestion; after typed text it is the rest of it, so a
footer offering `accept suggestion` never by itself means the box is empty.
Grok can also put text back into the box: a stash it restores after the
next send, or a prompt restored by a cancel-rewind or a rewind. The prompt
a cancel-rewind restored was drawn as plain text (live, 2026-10-20).

The footer is the last row under the box. With the prompt focused on the
main view it shows `Shift+Tab:mode`, first or second with an empty box but
third after a draft's hints, so a 62-column pane cuts it off (`Enter:queue │
Shift+Enter/Opt+Enter:newline │`, live, 2026-10-20):

- idle and empty: `Shift+Tab:mode │ Ctrl+.:shortcuts`;
- a draft: `Enter:send │ Shift+Enter/Opt+Enter:newline │ Shift+Tab:mode │
  Ctrl+.:shortcuts`, cut to `… │ Shift+Tab` at 62 columns and to
  `Enter:send │ Shift+Enter/Opt+Enter` at 40 (live, 2026-10-20);
- working: `Shift+Tab:mode │ Ctrl+c:cancel │ Ctrl+b:send to bg │
  Ctrl+.:shortcuts`, with `Ctrl+b` only while a tool runs; during
  `/compact` and during a wait on a described background task, only
  `Shift+Tab:mode │ Ctrl+.:shortcuts` (live, 2026-10-20);
- working with a draft: `Enter:queue │ … │ Ctrl+c:cancel │ Ctrl+Enter:send
  now │ …`, only `Enter:queue │` at 40 columns (live, 2026-10-20);
- items queued and an empty box: `Enter:send now │ … │ Ctrl+;:queue │ …`,
  where Enter sends the first queued item at once, cancelling the turn.
  While a tool ran it read `Enter:send now │ Shift+Tab:mode │
  Ctrl+c:cancel │ Ctrl+b:send to bg │ Ctrl+;:queue │ Ctrl+.:shortcuts` at
  120 columns, cut after `Ctrl+c:cancel │` at 62 and to `Enter:send now │
  Shift+Tab:mode` at 40 (live, 2026-10-20).

`Tab/→:accept suggestion` is pinned and shows only with prompt focus
(`views/agent.rs`). A pending double press replaces every hint with `press
again to <label>` (`app/app_view.rs`). Live (2026-10-20), one Ctrl+C on an
idle, empty box showed `Ctrl+c:press again to quit`, styled like other
hints, in place of every hint at 40×30, 62×41 and 120×40, for about 1.0 s
where timed, and Grok did not quit. Text pasted in that second did not
disarm it, and its Enter started the turn, whose working hints replaced the
footer. Hints stop at the pane's right edge. The Welcome screen's footer
holds only the channel tag (`[stable]`), with the name and version before
it below about 90 columns.

At 20 rows or fewer Grok forces compact mode (`views/agent.rs`
`AUTO_COMPACT_MAX_ROWS`), as at the phone's 62×20 grid with the keyboard
up. Its footer is only `Ctrl+.:shortcuts`, idle or working, with the prompt
or the scrollback focused, so it drops `Shift+Tab:mode` and `Ctrl+c:cancel`;
a card keeps its own hints, and an armed quit puts `Ctrl+c:press again to
quit` in its place, one column in like it (live, 2026-10-20). Only the
placeholder then shows that the prompt lacks focus. The scrollback's user
rows lose their `❯`: their text starts four columns in, as a reply's does,
on a shaded band (live, 2026-10-20), so only color tells a message from a
reply there.

`/minimal` switches the session to minimal mode, and `/fullscreen` back.
Neither changed `config.toml` (live, 2026-10-20), and the user guide's
slash-command page calls both session-scoped. Grok replays the session into
the terminal's own scrollback, past prompts flush left behind `❯`, and
prints `Switched to minimal mode · /fullscreen to go back`. Idle, it draws
`minimal · /fullscreen to go back · /help`, a bare `❯` row and an info row,
`Grok 4.7 Fast (high) · 30K / 256K (12%) · ctrl+o transcript`, which drops
`· ctrl+o transcript` at 40 columns; there is no box and no footer. While a
turn ran at 40 columns, the only width captured working, the rows above
`❯` showed the command (`$ sleep 30`) and a status row that filled the
width with no `[stop]` (`⠋ Sleep for 30 seconds…       18s ⇣30.3k`)
instead of the `minimal ·` row, and herdr reported the Agent idle for the
whole 35 s turn. `/fullscreen` brought the box back, with a `Switched to
fullscreen mode` toast (live, 2026-10-20).

While a turn runs, a status row above the box starts with a braille spinner
(U+2800–U+28FF), then a label, the elapsed times, tokens and `[stop]`:
`⠧ Sleep 40 seconds then echo two… 15s  18s ⇣25.8k [↓][stop]`. A card's
status row starts with `◆` instead. Between that row and the box sit dock
sections: `▾ Queued N` with `#n <text>` rows, `▾ Subagents N` with
`⋅ Subagent …` rows, and others such as `▾ Tasks N` with
`Run <description>` rows. Live (2026-10-20), a subagent or task row started
with `⁙`, `⸬` or `:` in different captures, and a section could show
collapsed, as `▸ Queued 1`. Labels include `Waiting for response…`,
`Thinking…`, `Preparing <tool>…`, `Writing command…`, `Responding…` and
`Compacting…` (during `/compact`), and by the source `Cancelling…`, which
never showed live: six cancels, one of them a command that ignored INT and
TERM, each left the spinner or the stop panel within one 130–260 ms screen
read, five for idle and the one with a message queued for that message's
`Waiting for response…`, and none of 1,194 saved frames held the row (live,
2026-10-20). A narrow pane cuts the label: `Waiting for…`, `Sleep fo…`, and
`Waiting for …` with a space for two subagents, at 40 columns (live,
2026-10-20). During some waits a plain Enter with text cancels the waiting
turn and runs the message next (user guide `03-keyboard-shortcuts.md`;
`views/turn_status.rs` `is_sendable_wait`): `Waiting for subagent…`,
`Waiting for 2 subagents…`, `Waiting on task output…`, `Waiting on tasks…`
and `Sleeping…`. A blocking wait on a background task that has a
description shows `<description>…`, like a running command: live,
`⠴ Sleep 45 seconds in background…  33s ⇣29.0k [stop]`, with no phase timer
and no `[↓]`. A message sent during such a wait was queued (`▸ Queued 1`,
footer `Shift+Tab:mode │ Ctrl+;:queue │ Ctrl+.:shortcuts`), and it ran as
the next turn after the wait's turn ended `end_turn` (live, 2026-10-20).
Toasts such as `Press Ctrl+c to cancel the turn` and `Input cleared · ctrl+z
to undo` also sit above the box.

Scrollback user rows are unboxed, five columns in: `❯ <text>` (without the
`❯` in compact mode, above), with a time at the right edge (`11:10 PM`, or
`HH:MM:SS | Mon D` while hovered) and sometimes a scrollbar glyph (`█`)
after it. A long prompt wraps and ends with `…`. Once a reply scrolls, Grok
pins the turn's prompt at the top as a sticky row, with `▲` under it (live,
2026-10-20).

Other views take the box's place or sit on it, and herdr reports all of them
idle or done:

- the Welcome modal, at start or after `/welcome`: the menu `New worktree
  ctrl+w`, `Resume session ctrl+r`, `Changelog` and `Quit ctrl+q`, and a
  `Tip:` row (live, 2026-10-20). From about 90 columns its menu sits in a
  box beside the logo; narrower, as at a phone's 40 to 62 columns, Grok
  stacks it under the logo without the box, and the footer reads `Grok
  Build <version> [stable]` (live, 2026-10-20). At start, the first message
  becomes the reported session's first prompt; after `/welcome`, text sent
  from it first starts a new session (see Identity and location). Ctrl+R
  there opens a full-screen `Resume session` list grouped by folder, with
  the footer `Esc:back │ Enter:select │ ctrl+w:worktree │ ↑↓:` at 62
  columns (live, 2026-10-20).
- the resume picker (`┌─ Resume session`, footer `↑↓ nav | e expand | /
  search | f filter | d delete`) and the rewind picker;
- the slash, `@` and `/model` popups, drawn above the box with a count at
  the end of their top rule. While the slash popup shows, the box draws the
  highlighted entry: `❯ /heeler-probe` after a typed `/hee` (live,
  2026-10-20);
- the prompt history panel, which ↑ opens on an empty box with nothing
  queued: a `─ history ─…<count>─` rule over recent inputs, commands such
  as `/welcome`, `/minimal` and `/fullscreen` among them, the selected one
  recalled into the box, and the footer `↑/↓:nav │ PgUp/PgDn:page │
  Enter:select │ Esc:cancel`. Esc closes it and empties the box. herdr
  reported idle while it covered a running turn's status row (live,
  2026-10-20);
- the `/btw` side panel (`╭─ /btw <question> … [Esc] ╮`);
- the dashboard: `+ New Agent`, `▾ Idle N` session rows, the dispatch box,
  and the footer `Enter:create │ Tab:input │ Ctrl+.:shortcuts`. Live
  (2026-10-20) at 62 and 120 columns, its header read `<branch> <cwd>
  [Choose Ctrl+l] … ◇ N idle` and the row below `+ New Agent … Open
  Previous /resume │ Worktree Ctrl+w`; at 40 columns both dropped their
  middle part (`[Choose Ctrl+l]`, `Open Previous /resume │`). It listed
  sessions from other folders too. Down selects the section's title
  (footer `Enter:collapse`), then a session, whose peek panel takes the
  dispatch box's place with that session's last exchange and a `❯` reply
  box (footer `Enter:open │ Tab:list │ Esc:New Agent │ Ctrl+x:archive`). A
  dispatch draft's footer reads `Enter:send │ Ctrl+s:send+open │
  Shift+Tab:mode │ …`. Esc from the dashboard without opening an agent
  returned to the plain view.

The header (`<branch> <cwd> <N>K / 256K │ [Dashboard]`) never shows the
session id.

Enter on a dashboard session opens that agent's own view, whose box sends
to that agent (1.0.45 source): `Ctrl+\:dashboard` comes first in the
footer, and `‹ i/n ›` sits in the header while there are other agents to
cycle to (`agent_view/render.rs`). Live (2026-10-20) at 62 columns, the
header read `Se… │ <branch> <cwd> <N>K / 256K │ ‹ 1/3 › │ [Dashboard]` and
the footer `Ctrl+\:dashboard │ Ctrl+[/]:prev/next agent │ Ctrl+x:`. Once an
agent had been opened, no key tried brought the plain view back, and a
restart did: Esc out of the dashboard showed the last opened agent in that
view, not the session shown before, and `/resume` to the earlier session
and Ctrl+\ twice kept the view's chrome. In every capture of the view its
scrollback marked the user's messages with `❯` at the plain view's indent,
and its empty box drew no placeholder (live, 2026-10-20). Each of those
captures was 62×41 with the prompt focused; none shows the view without
prompt focus, at 40 or 120 columns, or at 20 rows or fewer. So reading an
empty box there without `Build anything` as focused rests on the plain
view's placeholder (live) and the 1.0.45 source, and whether compact mode
keeps the view's `‹ i/n ›` and `Ctrl+\:dashboard` is unknown. A card there
replaces the footer's hints with its own (source).

Cards replace the input box with a panel of rows starting `┃`. Options read
`┃ <key> (○|●) <label>`, `●` marking the preselected row; the focused row
has a lighter background and a bold label.

- The permission card names a command (`┃ › <description>`,
  `┃ │ <command>` and a scope line) or an edit (`Allow Edit to <path>?`).
  A single command lists `Yes, and don't ask again for anything
  (always-approve mode)`, `Always allow: <cmd>`, `(●) Yes, proceed`,
  `No, reject (type to add feedback)` and `Never allow: <prefix>`; a
  compound command always-approve, `Yes, proceed` and reject, and none of
  the five captured offered `Always allow`; an edit always-approve, `Yes,
  allow all edits during this session`, `(●) Yes` and reject. Four
  compound commands (three joined with `&&`, one with `;`) also showed
  `← → narrow scope` and a fourth row, `Never allow: <prefix of the first
  command>`, with the footer `1/4:select │ Tab:next option │ ←/→:scope │
  Ctrl+o:` (live, 2026-10-20); one on 2026-10-19 showed neither. Row 1 is
  always the always-approve mode. A command card's footer reads
  `1/5:select │ Tab:next option │ ←/→:scope │ e:edit pattern │
  Ctrl+o:always-approve │ Ctrl+c:cancel │ Esc:scrollback`. A narrow pane
  cuts rows and the description: at 40 columns
  `2 (○) Always allow: chmod 644…` and `4 (○) No, reject (type to add f`,
  the description with `…`, and at 62 columns row 1 ends `(always-a`
  (live, 2026-10-20).
- The question card shows one question; options `1 (○) <label>
  <description>`, where a label may end `(Recommended)`; and `z (○) Type
  your answer here`. Nothing is preselected. Its footer reads `Tab:next
  answer │ Esc:scrollback │ Shift+x:dismiss`, under the status row
  `◆ Waiting on answers for <question>`.
- The rewind confirmation offers `y (●) Yes`, `a (○) Yes, and don't ask
  again` and `n (○) No`.
- The `/fork` worktree question is a question card, `Run this fork in an
  isolated git worktree?`, with `1 (○) Yes  Fork in a new isolated git
  worktree`, `2 (○) No  Fork in the current cwd`, `3 (○) Always worktree
  Use worktree and stop asking…`, `4 (○) Never worktree  Skip worktree and
  stop asking…` (both cut with `…` at 62 columns) and `z (○) Type your
  answer here`, and the question card's footer (live, 2026-10-20); 3 and 4
  write the config. At 40×30 only row 1 and `z` showed, and `2` still
  answered No (live, 2026-10-20). No turn waits on it, so no `◆ Waiting on
  answers` row stands above it, and its answers carry a scrollbar of their
  own, a `█` column at the card's right edge (live, 2026-10-19 and
  2026-10-20).
- Starting a subagent asks first, under the status row `◆ Waiting for
  subagent…`: `┃ ›  Allow <description>?` with `1 (○) Yes, and don't ask
  again for anything (always-approve mode)`, `2 (●) Yes, send once` and
  `3 (○) No, reject (type to add feedback)`, and the footer `1/3:select │
  Tab:next option │ Ctrl+o:always-approve │ Ctrl+c:cancel │
  Esc:scrollback`. herdr reported it Blocked, and Enter or `2` approved
  once (live, 2026-10-20). At the phone's 62 columns row 1 ends
  `(always-a` and the footer stops after `Ctrl+o:always-approve` (live,
  2026-10-20). Two parallel subagents with one description asked one after
  the other on identical cards, which differed only in the status row's
  timers, and herdr stayed Blocked from the first card until 0.25 s after
  the second's approval (live, 2026-10-20).
- Ctrl+C while subagents run opens a stop panel, `Subagents are still
  running. Stop them?`, with `1 (●) Stop running`, `2 Continue to run`,
  `3 Always stop` and `4 Always continue`, and the footer `1/4:select │
  Tab:next choice │ Enter:confirm │ Esc:keep running`.

The plan-approval card, the MCP elicitation card and the prompt-blocked
card were not captured. Permission cards depend on configuration: where
Claude Code's `~/.claude/settings.json` sets `permissions.defaultMode:
"auto"`, Grok imports it and runs in Auto-review. No card appeared and herdr
never reported Blocked, even with `[ui] permission_mode = "ask"`,
`--permission-mode default` or `GROK_AUTO_PERMISSION_MODE=0`; cards appeared
only with `HOME` pointing elsewhere. Even there, with
`[ui] permission_mode = "ask"`, Grok ran `sleep`, `touch` and an `ls -la`
without a card (live, 2026-10-20).

Keys, live unless marked:

- Ctrl+C cancels a running turn with an empty box within 0.4 s; after one,
  the scrollback read `Turn cancelled by user in 16s.` (live, 2026-10-20).
  Esc never cancels; it shows the toast `Press Ctrl+c to cancel the turn`.
  1.0.6x has no Esc cancel, although the census shows `esc` cancels until
  September 2026.
- With a message queued, Ctrl+C cancelled the running turn, and Grok
  started the queued one 11 ms later (live, 2026-10-20).
- Ctrl+C on a draft only clears it, whether a turn runs or not.
- Ctrl+C before the first output is the cancel-rewind above.
- With subagents running, Ctrl+C opens the stop panel. There only Esc keeps
  the turn running; `Continue to run` still ends the parent turn, and only
  the subagents survive (source: `app/agent_view/key_owner.rs`).
- Ctrl+C on an idle, empty box arms quit for about a second without
  quitting (the footer above; live, 2026-10-20). By the source a second
  Ctrl+C or Ctrl+D within 1,000 ms quits; no second press was tried.
- Ctrl+C on a permission card drops the card and ends the turn in one press
  (`PermissionCancelled`), without arming quit (live, 2026-10-20).
- Source only: while a cancel is pending, Ctrl+C maps to quit (no pending
  cancel showed live, above); on the Welcome screen's resume picker one
  press quits; on a question it skips.
- Esc twice within 800 ms on an empty idle box opens the rewind picker. On
  a card, Esc parks focus in the scrollback and answers nothing: the card
  stays drawn, the footer read `Tab/Space:question │ Ctrl+e:` at 40
  columns, and Tab gives the card focus back (live, 2026-10-20).
- ↑ on an empty box with messages queued focuses the queue: the selected
  row gets `[Send now][edit][cancel]`, the box shows `❯ Build anything`, and
  the footer reads `x:delete row │ e:edit │ Shift+j/k:reorder │ y:copy`.
  There `e` edits the message in the box (footer `Enter:save │ Esc:cancel │
  Ctrl+c`, cut at 40 columns) and Esc gives the prompt focus back, while
  Esc in the queue itself focuses the scrollback (footer `Ctrl+e:expand
  thinking │ Space:prompt │ Ctrl+c:cancel`), where Space gives the prompt
  focus back. With nothing queued, ↑ opens the history panel (live,
  2026-10-20).
- A row's key (a digit, or `a`–`f` on a question) selects and submits at
  once; on a card with several questions it moves to the next one. The
  numbers change with the card's shape, so a key is chosen by its label.
  A letter typed on the reject row opens a feedback field instead, and
  Ctrl+Y hides a question without answering it, leaving the tool waiting.

`agent.prompt` pastes, then presses Enter 300 ms later. What Grok does with
it:

- A draft in the box, typed, restored by a cancel-rewind or a rewind, or
  left by a refused `/goal`, is joined with the paste and sent as one
  prompt.
- While Grok works, the message is queued (`▾ Queued 1`) and becomes the
  next turn. Its records were written when that turn started, 27 s after
  the send in one capture and 37 ms after the previous `turn_completed`;
  herdr stayed working across the handoff. Two more were written 10.4 s and
  36.9 s after the send, the second 24 ms after the previous
  `turn_completed`, and herdr again reported working throughout (live,
  2026-10-20). A message sent within 0.3–0.5 s of a submit arrives while
  herdr still reports idle or done.
- On the dashboard it dispatches a new agent.
- On the Welcome screen that `/welcome` opens, it first starts a new
  session (see Identity and location).
- `exit`, `quit`, `:q`, `:q!`, `:wq` and `:wq!` quit at once (source; the
  1.0.62 binary compiles these short literals to integer compares, so its
  strings can't confirm them).
- A `/btw` token anywhere turns the whole message into a side question that
  never reaches `updates.jsonl`. A `/goal` token after the start is refused
  with the toast `Slash commands only work at the start of the message: put
  /goal … first.` and stays in the box, while `agent.prompt` still
  succeeds. A token is `/` at the start or after ASCII whitespace, up to the
  next whitespace (`slash/mod.rs`), so `/btw,` is not one.
- `/model ` puts the highlighted model in the box and opens a context-size
  list, so the next Enter would switch models. An unknown `/foo bar ` goes
  to the model as text.
- `/new`, `/clear`, `/compact`, `/resume`, `/fork`, `/dashboard` and `/quit`
  ran with Heeler's trailing space, and so did `/welcome`, `/minimal` and
  `/fullscreen` (live, 2026-10-20). A pasted `/home ` named a path (see
  Identity and location).
- A pasted leading `!` stays text, without Bash mode, but the model ran the
  command as a tool anyway. A pasted leading `#` stayed text too, with
  `[features] remember_mode` unset: `# Reply with the word cherry ` was
  recorded as sent, its `prompt_history.jsonl` line had `is_bash: false`,
  and no frame showed Remember mode (live, 2026-10-20). Only a typed `#`
  enters Remember mode (source).
- In `/multiline` mode Enter adds a line, so nothing is sent (source); with
  `/multiline` typed in the box the footer started `Shift+Enter:send` (live,
  2026-10-20).
- A skill runs as `/name args`: `/heeler-probe alpha beta ` ran the skill,
  and the slash popup did not take the Enter (live, 2026-10-20). By the user
  guide (`08-skills.md`), project skills load only in a trusted folder;
  skills added to an untrusted folder while Grok ran were not listed, and a
  restart with `GROK_FOLDER_TRUST=0` listed them (live, 2026-10-20). A skill
  named like a built-in command runs the built-in, and is reachable only as
  `/local:<name>` or `/user:<name>` (user guide `04-slash-commands.md`); the
  popup listed a project skill named `undo` as `/local:undo` beside the
  built-in `/undo` (live, 2026-10-20).

## Open questions

Not captured yet:

- F1: a skill sent in its `/local:` form.
- F3: a second Ctrl+C while a cancel is pending, and the `Cancelling…` row.
  Tried on 2026-10-20: six cancels (four commands, one of them with a
  message queued and one ignoring INT and TERM, a cancel-rewind, and the
  subagent stop panel) each left the spinner or the panel within one
  130–260 ms screen read (five for idle, the one with a message queued for
  that message's turn), `herdr pane wait-output` for `Cancelling` or
  `press again` timed out each time, and none of 1,194 saved frames showed
  the row, so no second Ctrl+C was pressed.
- F5: a reject with typed feedback, which continues the turn.
- F6: question variants: a skip with Ctrl+C or Shift+X, a free-text answer,
  several questions, and multi-select.
- F7: an image prompt's chunk.
- F8: every `retry_state` variant and an error turn.
- F10: the dashboard's Ctrl+N, and a session closed in its details view and
  reopened with `/resume` (`/quit` in the dashboard's agent view closed
  one, and a restart with `--resume` reopened it).
- F11: steer mode's interjection chunk (needs a config change).
- F12: why `GROK_AUTO_PERMISSION_MODE=0` alone did not bring cards back.
- F13: plan mode's approval card.
- F15: a hook cancel's `cancellationCategory`.
- F17: what `Always allow: <cmd>` and `Yes, allow all edits during this
  session` keep, and whether they outlive a restart.
- F18: `prompt_history.jsonl` for a session in a worktree group, and its
  rewrite at 10,000 entries.
- F19: Esc on the subagent stop panel.
- F21: at 120×40, a Session line after `/new` and a working screen with
  nothing queued (the other screens were captured at 40×30, 62×41 and
  120×40).
- F22: a pasted `#` with `[features] remember_mode` on.
- F23: focus states: Tasks and Todo focus, and a subagent's child view.
- F24: prompt suggestions: the ghost at 40 and 120 columns, typed text plus
  a ghost, and a stash restored after a send.
- F25: the `Sleeping…` wait (tried: the pause call wanted task ids, and the
  model then waited on its task).
