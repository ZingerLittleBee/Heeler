# OpenCode session store

Observed on 2026-10-19, at phone width on 2026-10-20, and through the app on
2026-10-21, with OpenCode 2.0.32 under herdr 0.9.5, on macOS with SQLite
3.54.0. This note records what native Chat relies on to follow an OpenCode
Agent: where OpenCode keeps a conversation, which tables and rows hold it,
how they change while OpenCode works, what herdr and the terminal screen
show, and what reading it costs.
[ADR 0025](../adr/0025-opencode-chat-reads-its-session-store.md) records the
read path built on it.

## Evidence and provenance

| Source | Version | Cited as |
| --- | --- | --- |
| OpenCode source | `anomalyco/opencode` tag `v2.0.32` (`843a6c51`, 2026-10-16), the `@opencode/cli` line | `<package>/src/<path>:<lines>`, relative to `packages/` |
| herdr source | tag `v0.9.5` | herdr `src/<path>:<lines>` |
| Store census | one development machine's store, read through a read-only backup: 446 2.x sessions, 6,481 rows, 281 MB; keys, JSON types, counts and sizes only | "census" |
| Query bench | `/usr/bin/sqlite3` 3.54.0, read-only, against that live store while OpenCode's background service held it | "bench" |
| Live capture A | OpenCode 2.0.32 in a herdr pane at 180 by 47 cells, in a scratch project with scratch prompts; the store, `herdr agent get` and the screen polled every 300 ms | labels `a1` to `a11b`, `e1` to `e4` |
| Live capture B | the same in a second scratch project; one aggregated `SELECT` and `herdr agent get` sampled every 150 ms | labels `B1` to `B9`, `Bbusy`, `Besc`, `Bpaste1`, `Bpaste2`, `Bat`, `Bcompact` |
| Phone-width capture | OpenCode 2.0.32 on an isolated herdr 0.9.5 server on 2026-10-20, in a scratch project with scratch prompts. A 180 by 47 client, then a pty-attached `herdr agent attach` at 62 by 41 cells, sized the pane, which kept that size after each detach; `agent.read` read the visible screen | Chat fixture stems `opencode-22`, `opencode-25` (180 by 47) and `opencode-30` to `opencode-43` (62 by 41) |
| In-app check | OpenCode 2.0.32 on an isolated herdr 0.9.5 server and `sshd` on 2026-10-21, in a scratch project with scratch prompts, its pane focused at 119 by 40 and then 62 by 41 cells under the app on a Simulator; herdr's `pane.agent_status_changed` events, `herdr agent get` read about every 250 ms, herdr's server log and a wrapper on the `sshd` that timed each exec, beside the store | "2026-10-21" |

The live captures used one OpenAI model (GPT-6 Astra, variant `high`); other
providers may fill text and reasoning differently. The captures stay outside
the repository; Chat fixtures sanitized from them name the label they came
from. Only structure was taken from the development machine's own sessions:
every prompt, text and file name quoted here comes from the scratch sessions.

Statements marked **(source)** were read in source and not observed; the rest
were observed in the captures, the census, the bench or the in-app check.
[Open items](#open-items) lists what is still unverified.

## Location and files

- The store is `opencode.db` in OpenCode's data directory:
  `$XDG_DATA_HOME/opencode` when `XDG_DATA_HOME` is set to any non-empty
  value, else `~/.local/share/opencode` (`util/src/global-roots.ts:5`).
  `OPENCODE_DB` replaces the file name, resolved against that directory (an
  absolute path stands as is, and `:memory:` keeps no file at all).
  Builds from the `latest`, `dev`, `beta`, `next` and `prod` channels share
  `opencode.db`; other channels use `opencode-<channel>.db` unless
  `OPENCODE_DISABLE_CHANNEL_DB` is `1` or `true`
  (`cli/src/database-path.ts:4-13`).
- The same directory holds `tool-output/` (full tool output, kept for 7 days,
  `core/src/tool-output.ts:13-16`), `snapshot/` and `log/`. The background
  service's password is in `~/.config/opencode/service.json`, and provider
  credentials are in the database's `credential` table.
- The database uses WAL mode and 4,096-byte pages, and leaves `user_version`
  at 0. Two tables record migrations: `__drizzle_migrations` (the 1.x runner)
  and `migration` (2.x, one row per migration). Every OpenCode process that
  opens the database applies pending migrations
  (`core/src/database/database.ts:39-49`); the first start of 2.0.32 applied
  three in place.
- `opencode --version` and `--help`, run in a scratch home directory, created
  OpenCode's directories and appended a log line, but did not create or open
  `opencode.db`.

### Side files and read-only opens

- While any OpenCode process has the database open (the TUI, or the
  background `opencode serve --service`), `-wal` and `-shm` exist and
  `sqlite3 -readonly` reads it. The captures made about 8,500 such reads
  while OpenCode wrote, none of them locked, busy or unable to open.
- A read-only open of a WAL database whose `-wal` and `-shm` are absent
  depends on the build. Apple's SQLite 3.54.0 refuses it with `unable to
  open database file (14)`: `sqlite3 -readonly`, URI `mode=ro` and Python's
  `mode=ro` alike; only URI `immutable=1` opens it. Stock SQLite (3.22 and
  later) creates both files to open it, and leaves them when it closes:
  Homebrew's 3.53.3, and Python's 3.40.1 (Debian 12) and 3.46.1 in
  containers, all read such a store this way.
- Stock SQLite deletes both files when the last connection closes, as the
  same containers showed; Apple's build kept them after close in this test.
  So on Linux every store that no OpenCode process holds open lacks them, and
  a read-only open would leave them in OpenCode's data directory. The probe
  therefore starts no reader while either file is absent, and reads such a
  store as closed (ADR 0025).

## Tables

OpenCode 1.x (`opencode-ai`) and 2.x share the file. 1.x tables are
`session`, `message`, `part` and `todo`; 2.x tables are `session_v2`,
`session_message`, `session_inbox`, `session_pending`, `event` (empty, since
durable events are not persisted by default), `event_sequence` and
`instruction_*`; `project`, `permission`, `kv` and others serve both. 2.x
imports 1.x sessions into `session_v2` under the same ids (438 of the 446 in
the census), after which the 1.x tables stay frozen.

A 2.x conversation lives in four tables:

| Table | Columns (census order) | Indexes |
| --- | --- | --- |
| `session_v2` | `id`, `project_id`, `workspace_id`, `parent_id`, `fork_session_id`, `fork_boundary`, `slug`, `directory`, `path`, `title`, `version`, `share_url`, four `summary_*`, `metadata`, `cost`, five `tokens_*`, `revert`, `permission`, `agent`, `model`, `time_created`, `time_updated`, `time_compacting`, `time_archived`, `time_suspended`, `resume_attempts`, `time_idle`, `time_viewed`, `idle_outcome` | primary key `id`; `project_id`; `workspace_id`; `parent_id`; partial on `time_suspended` |
| `session_message` | `id`, `session_id`, `type`, `seq`, `time_created`, `time_updated`, `data` | primary key `id`; unique `(session_id, seq)`; `(session_id, type, seq)`; `(session_id, time_created, id)`; `time_created` |
| `event_sequence` | `aggregate_id`, `seq`, `owner_id` | primary key `aggregate_id` |
| `session_inbox` | `id`, `session_id`, `type`, `payload`, `delivery`, `enqueued_seq`, `time_created` | primary key `id`; unique `(session_id, enqueued_seq)`; `(session_id, delivery, enqueued_seq)` |

- `session_message.data` is the message encoded without its `id` and `type`
  (`core/src/session/sql.ts:20, 79-98`).
- `time_updated` has no index, but it comes before `data` in the row, so
  filtering a session's index range on it does not read `data`'s overflow
  pages.
- `session_v2.revert` holds a staged revert (see [Revert](#revert)).
  `time_suspended` is the running execution's claim, despite its name
  (`core/src/session/store.ts:205-224`).

## Ids and times

- Session ids match `^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$`; message and queue
  ids have the same shape with `msg_`, and 1.x part ids with `prt_`. The 12
  hexadecimal digits encode `Date.now() * 0x1000 + counter`, bit-inverted for
  sessions so that newer ones sort first, and the 14 characters are random
  (`schema/src/identifier.ts:3-31`). Every stored and reported id matched.
- OpenCode itself checks only the prefix: `opencode --session <id>` creates a
  session under any id it is given, and a fork copies rows under
  `msg_<26 characters>_<seq>` ids (`core/src/session/projector.ts:218`).
- Tool call ids are the provider's: `call_` and 24 letters or digits, or
  `functions.name:0` and similar forms.
- Every time, in columns and in JSON, is Unix epoch milliseconds.
- A subagent's session points at its parent through `parent_id`. The census
  held sessions two levels deep.

## Rows

`session_message.type` has eleven values (`schema/src/session-message.ts`).
The census counted, among 2.x rows: `assistant` 5,578, `user` 855,
`synthetic` 27, `idle` 17, `compaction` 2, `system` 1 and
`location-switched` 1.

| Type | `data` |
| --- | --- |
| `user` | `text`, `files[]` (`{data, mime, name, mention{start, end, text}, source{type}}`), `agents[]`, `skills[]`, `metadata?`, `time.created` |
| `assistant` | one model step: `agent`, `model{id, providerID, variant}`, `content[]`, `snapshot{start, end, files[]}`, `finish`, `providerState?`, `cost`, `tokens`, `error?{type, message}`, `retry?{attempt, at, error}`, `time{created, streamed?, completed?}` |
| `idle` | `outcome` (`succeeded`, `failed` or `interrupted`), `error?` |
| `compaction` | `status` (`running`, `completed` or `failed`), `reason` (`auto` or `manual`), `summary` and `recent` (the one failed row seen had neither), and the model, cost and tokens once completed, or `error{type, message}` once failed |
| `synthetic` | `text`, `description?`, `metadata?{source (subagent or shell), childID?, jobID?, shellID?, state, exit?, truncated?}` |
| `system` | `text`, `description` ("Instructions updated: …"), `metadata.notice` |
| `skill` | `skill`, `name`, `text` |
| `shell` | a `!` command typed in the TUI: `shellID`, `command`, `status` (`running`, then `exited`), `exit?`, `output?{output, cursor, size, truncated}` once it ends, `metadata{background}`, `time{created, completed?}` |
| `agent-switched` | `agent`, `previous?` |
| `model-switched` | `model`, `previous?` |
| `location-switched` | `location`, `projectID?`, `subpath?`, `previous?` |

`skill` rows were not in the census or any capture, nor were
`model-switched` rows (F6). The in-app check saw `agent-switched`.
`shift+tab` switched Build to Plan with no row and the counter unchanged;
the next prompt wrote `agent-switched` `{agent: plan, previous: build}`,
then a `synthetic` row with only `text`, then its `user` row, and its steps
carried `agent: plan`. That text is a reminder to the model, a
471-character `<system-reminder>` ("You are in Plan mode. …"), written once
per switch: a second Plan prompt wrote neither row, and switching back to
Build wrote another pair ("You are NO LONGER in Plan mode. …"). The
terminal showed "Switched agent from Build to Plan" above the prompt and
never the reminders.

OpenCode's session view draws no `synthetic` row without a description (a
blank one counts as none), whether it builds the transcript or the row
arrives live, and its web timeline draws one only with a description or an
error in its metadata **(source,
`tui/src/routes/session/rows.ts:254-259, 267-270, 383`;
`session-ui/src/timeline/projection.ts:1050-1056`;
`session-ui/src/timeline/detail.ts:111-121`)**. The Plan plugin writes both
reminders with only text (`core/src/plugin/plan.ts:14-25, 57-96`), as do
the request to move running work to the background and the 1.x importer
for a message's synthetic text **(source, `core/src/session.ts:442-458`;
`core/src/database/v1-migration.bun.ts:337-370`)**. Chat likewise shows no
`synthetic` row with neither metadata nor a description, and keeps the
`agent-switched` row's notice.

A `shell` row was seen in the in-app check: `running` with no `output` while
the command ran, then `exited` with `exit` and `output`. That `output` is
not the text but an object with OpenCode's `Shell.Output` fields
(`schema/src/shell.ts:77-84`): the text in `output.output`, and `cursor`,
`size` and `truncated`, a page of the command's capture that OpenCode reads
with a 1 MiB limit **(source, `core/src/session/shell.ts:23-24`)**. The
command ran in the background (`metadata.background` is `true`) while herdr
stayed `idle`, and OpenCode queued an inbox `synthetic` note
(`metadata.source` `shell`) that the next prompt commits.

### Assistant steps

- `content[]` items are `text {text, state?}`, `reasoning {text, state?,
  time}` and `tool {id, name, executed?, providerState?,
  providerResultState?, state, time{created, ran?, completed?}}`.
- `finish` is `stop`, `tool-calls`, `length`, `error`, `content-filter` or
  `unknown` (`schema/src/llm.ts:5`); the census counted `tool-calls` 5,008,
  `stop` 516, `length` 1 and `error` 1. `error.type` values were `aborted`
  46, `unknown` 3 and `provider.error` 2; a refused connection in the in-app
  check recorded `provider.transport`. `retry` was not in the census; the
  in-app check saw it while a provider failed (see [Turns](#turns)).
- With this OpenAI model, text items carried `state.itemId` and
  `state.phase` (`commentary` or `final_answer`), and reasoning items kept
  `text: ""` with about 1.6 KB of `state.reasoningEncryptedContent`. The TUI
  shows nothing for an empty reasoning item.

### Tool items

- A tool item goes `streaming` (its input still a raw string), `running` (an
  input object; `time.ran` set), then `completed` (`content[]`, `metadata?`)
  or `error` (`error{type, message}`). A fast tool can pass `running` between
  two polls 300 ms apart. At rest the census held `error.type`
  `tool.execution` 194 times and `aborted` once.
- `aborted` messages: "Tool execution interrupted" after Esc stops a turn,
  "The user declined this tool call" after a rejected permission, and "The
  user dismissed this question" for a dismissed question
  (`core/src/tool/plugin/question.ts:32-36, 96-97`; seen on 2026-10-21).
- The built-in tools of 2.0.32 are `edit`, `glob`, `grep`, `mcp-resource`,
  `opencode`, `patch`, `question`, `read`, `shell`, `skill`, `subagent`,
  `webfetch`, `websearch` and `write`, and codemode's `execute`; there is no
  todo tool. Rows that older 2.0.x builds imported from 1.x keep `bash`,
  `task`, `apply_patch` and `todowrite`; the current importer renames the
  first three to `shell`, `subagent` and `patch` and drops `todowrite`
  (`core/src/database/v1-migration.bun.ts:899-901`). Plugin tools appear
  under their own names (`background_output`, `call_omo_agent`,
  `ast_grep_replace`, `grep_app_searchGitHub`, and others in the census).
- A row keeps at most 2,000 lines or 50 KiB of a tool's output and sets
  `metadata.truncated`; the full output goes to `tool-output/`, named by
  `metadata.outputPath`, for 7 days. The census had `truncated` on 8,419
  items and `outputPath` on 13.
- File changes in 2.0.32 are
  `metadata.files[{file, patch, additions, deletions, status}]`, `status`
  being `added`, `deleted` or `modified` (`schema/src/file-diff.ts:6-23`),
  written by `edit`, `write` and `patch`. Patches come from
  `createTwoFilesPatch` and start with `Index:` and `===` lines. Older rows
  hold `metadata.diff` (715 in the census), `metadata.filediff` (712, with
  whole before and after copies of the file), or `files[]` with `filePath`,
  `relativePath`, `diff` and `type`.
- `shell`: input `{command}`, `content[{type: text, text}]`,
  `metadata{status, truncated, exit}`, plus `shellID` when interrupted.
- `read`: input `{path, offset?, limit?}`, a path the model may give relative
  to the session's location. OpenCode resolves it against
  `location.directory`, not the subpath, expanding a leading `~/`
  **(source, `core/src/file-access.ts:67-94`)**. An image or PDF comes back as
  `content[{type: text, text: "Image read successfully"` or `"PDF read
  successfully"}, {type: file, uri: "data:<mime>;base64,…", mime, name}]`,
  `name` being the path it read: the input's, or a file of another case it
  found in the same folder **(source, `core/src/tool/plugin/read.ts:62-79,
  175-185`)**. Seen live on 2026-11-02 with input `{"path":"shots/x.png"}`
  and `name` the same.
- A move rewrites the session's `directory` (and `path` to the subpath) and
  writes a `location-switched` row whose `previous.location.directory` is
  where it was **(source, `core/src/session/projector.ts:475-490`;
  `core/src/session/message-updater.ts:119-133`)**, so only the newest
  folder is in `session_v2`.
- `patch` (the edit tool this model used): input `{patchText}`, the content
  "Success. Updated the following files:" with one line per file, and
  `metadata.files` as above.
- `question`: input `questions[{question, header, options[{label,
  description}]}]`, already in the row while the tool runs and herdr reports
  Blocked. After an answer, `metadata.answers` (`[["blue"]]`) and the content
  "User has answered your questions: …".
- `subagent`: input `{agent, description, prompt, sessionID?, background?}`,
  `metadata{sessionID, status, truncated}` with the child's id, and the
  content `<subagent sessionID="…" state="completed">…</subagent>`. The child
  is a `session_v2` row whose `parent_id` is the caller, whose title is the
  description and whose agent is `general`; its first user row starts "You
  are a subagent spawned by another session." A background subagent reports
  its end later as a `synthetic` row with `metadata.source` `subagent`
  **(source, `core/src/session/subagent-completion.ts:43`; F9)**.

## Turns

Rows are ordered by `seq`, never by `time_created`: an assistant row's
`time_created` is its step's start, which can be 14 s before the row is
written. A simple turn's rows had `seq` N, N+1 and N+6, because `seq` counts
every durable event of the session.

| Case | Rows |
| --- | --- |
| Normal turn | `user`, one `assistant` per step, `idle(succeeded)` |
| Steer while working | `user`, `assistant`, a second `user` (the steer, promoted at the step boundary), `assistant`, one `idle` |
| Esc twice (stop) | the running tool `error`/`aborted`; the step `finish: error` with `error{aborted, "Step interrupted"}`; `idle(interrupted)`. Partial text stays (189 characters in `Besc`) |
| Esc twice with a steer waiting | `idle(interrupted)`, then the steer's `user` row 4 to 6 ms later and a new run of steps with its own `idle` (three runs, 2026-10-21) |
| Reject a permission (Reject or Esc) | the tool `error`/`aborted` "The user declined this tool call"; the step `finish: error`; **no `idle` row**. `idle_outcome` and `time_idle` keep the previous turn's values, and `time_suspended` stays set |
| Dismiss a question (Esc) | as a reject: the question tool `error`/`aborted` "The user dismissed this question", the step `finish: error` with `error{aborted, "Step interrupted"}`, and no `idle` row (2026-10-21; the session's columns were not read) |
| Reject with feedback (a subagent's request) | the tool fails with the feedback and the turn goes on **(source, `core/src/permission.ts:248-253, 276-283`; F3)** |
| `/redo` | a bare `idle(succeeded)` with no prompt |
| `/undo` | no row change; `session_v2.revert` is set |
| The next prompt after `/undo` | rows from the boundary on are deleted, then the new `user` row is inserted |
| `/compact` | `compaction(running)`, updated in place to `completed`, then `idle(succeeded)`; no `user` row. With nothing new since the last compaction, `compaction(failed)` with `error{compaction.unavailable, "Nothing to compact yet"}`, then `idle(succeeded)` (2026-10-21) |
| Esc twice during `/compact` | the compaction row updated in place to `failed` with `error{aborted, "Compaction cancelled"}`, then `idle(interrupted)` **(source, `core/src/session/runner/llm.ts:150-157`, `core/src/session/message-updater.ts:147-148`, `core/test/session-runner.test.ts:3018-3043`)** |
| Provider failure (a refused connection, retried) | while OpenCode retries, the step's open `assistant` row carries `retry` and no other row is written; then the step `finish: error` with `error{provider.transport, …}` and no content, and `idle(failed)` with the same error (2026-10-21) |
| Background service restart during a turn | a `synthetic` row with `description` "Continuing after restart" and `metadata.notice` `restart`, then the turn resumes; after 10 attempts it fails with "Execution was interrupted repeatedly…" **(source, `core/src/session/execution/restart.ts:15-33, 77-99, 193-228`; F1)** |

- A reject ends the step through an interrupt without a reason, which
  OpenCode records as a shutdown, and a shutdown writes no `idle` row
  (`core/src/session/runner/step.ts:274-277`,
  `core/src/session/execution.ts:50-54`,
  `core/src/session/projector.ts:421`). It also keeps the execution claim:
  `time_suspended` was still set 7 s after an Esc reject (`B7c`). If the
  background service restarts before the next turn, OpenCode resumes the
  rejected turn on its own **(source; F1)**.
- Neither `time_suspended` nor `idle_outcome` says whether a turn runs: both
  stay stale after a reject.
- An assistant row appears only with the provider's first output
  (`core/src/session/runner/publish-llm-event.ts:129-145`): 14 s after the
  prompt in one turn, 2.5 to 9.5 s in others. A text block is written empty
  and filled when it ends: a 265-character answer stayed empty for about
  6.7 s and a 313-character one for 6.6 s, while the screen streamed them.
- `/compact` inserts its row at once and fills it when done; one took 12.5 s.
  `session_v2.time_compacting` stayed null. Compaction deletes nothing: the
  model's context starts at the latest completed compaction, and the rows
  above it stay. Automatic compaction (`reason: auto`) was not observed live
  (F10).
- The in-app check made a provider fail with a project `opencode.json` that
  named an OpenAI-compatible provider at a closed local port, with a dummy
  key, so no stored credential or user setting was touched. OpenCode
  retried for 83 s. Meanwhile the step's `assistant` row stayed open with
  no content and `retry{attempt, at, error}`: the attempt it waited for,
  when that attempt was due, and the last error ("ConnectionRefused: Unable
  to connect. Is the computer able to access the url?"). In both snapshots
  the row kept its id and `seq`, and its `time_created` was the latest
  attempt's start. The counter kept moving (12 at the fifth attempt, 28 at
  the end) while only the `idle` row was added. Between attempts the screen
  counted down from 3, 5 and 9 s, then from 9 to 12 s (reads about 1 s
  apart). When the eleventh attempt failed, the row lost `retry` and ended
  as in the table, `idle(failed)` followed within 1 ms, and the session was
  never titled.

## Change detection

- Every durable event commits in one `BEGIN IMMEDIATE` transaction that runs
  the projectors and raises `event_sequence.seq` for its aggregate, the
  session (`core/src/bus.ts:315-434`). A new row's `seq` is that event's
  sequence (`core/src/session/projector.ts:395-410`), so every new row has a
  higher `seq` than any row before it.
- The counter moved in the same poll as every row change in both captures:
  105 of 105 changes in capture A, row inserts, updates and deletes, the
  session's revert, title and idle fields, and queue changes included. It
  also moves without a row change: when OpenCode titles the session, when the
  picker opens a session (`session.viewed`), and when a revert is staged or
  cleared. A pending permission does not move it, because permission events
  are not durable; the only change while Blocked in one capture was the
  tool's `streamed` stamp. Switching the agent with `shift+tab` did not move
  it either (2026-10-21). While a subagent runs, only the child's counter
  moves; the parent's stood still for about 8 s.
- Rows change in place only in three cases: the newest assistant row of each
  step, filled as the step runs and finally given `finish`, tokens, cost and
  `time.completed` (while a failing step retried in the in-app check, its
  `time_created` and `retry` followed the latest attempt in both snapshots);
  the compaction row, from `running` to `completed` or `failed`; and shell
  rows, from `running` to `exited` (seen in the in-app check). `seq` never
  changes, and `time_updated` takes the writer's clock at every update
  (`projector.ts:241-255`, through the column's `$onUpdate` in
  `core/src/database/schema.sql.ts:7-9`). In 2.0.32 an assistant row with
  `time.completed` is final until a revert commit deletes it:
  `MessageContentUpdated` is replay-only
  (`schema/src/session-event.ts:142-153`).
- Text, reasoning and tool-input deltas, tool progress and usage updates are
  ephemeral events and never reach the store
  (`schema/src/session-event.ts:167, 404, 443, 487, 520`).
- `session_v2.time_updated` is not a change signal: several projections keep
  it unchanged on purpose (`projector.ts:68, 435, 542, 609`).

## Revert

- `/undo` interrupts any running turn, stages a revert to the last user
  message, and puts that prompt back into the input box
  (`tui/src/routes/session/index.tsx:975-1030`). The store keeps every row
  and sets `session_v2.revert` to `{messageID, snapshot, files[]}`; the
  counter moves by one and herdr's status does not change. The TUI hides the
  rows from the boundary on and shows `1 message reverted` and
  `ctrl+x r or /redo to restore`.
- `/redo` clears `revert` and appends a bare `idle(succeeded)`. herdr reports
  `working` for about 200 ms, then `done`; in the in-app check, with the
  pane focused, its events read `working` for 105 and 110 ms, then `idle`.
- The commit runs when the next prompt is admitted, on compaction, or
  explicitly (`core/src/session/session.ts:165, 251`). In one transaction it
  deletes the rows whose `seq` is at or above the boundary message's, the
  `/redo` idle row included, and the queue rows enqueued from that `seq` on,
  and clears `revert` (`projector.ts:759-795`); the new prompt is admitted
  after it, in transactions of its own. In capture B one sample saw the row
  count fall from 10 to 7 while the highest `seq` rose from 38 to 45. A slow
  poll can also see the count unchanged (three rows deleted, three added), so
  only comparing the count of the rows a reader already holds catches the
  deletion.
- After the commit OpenCode no longer offers `/redo`: in the in-app check,
  typing it made `/reload  Reload configuration` the popup's top match, so
  Enter would have reloaded OpenCode's configuration.
- A staged revert carries full file patches
  (`core/src/session/revert.ts:42-49`, `projector.ts:739-743`).

## Queue of waiting prompts

- Every prompt passes through `session_inbox` as a row with `type` `user`,
  `delivery` `steer` by default and `payload` `{text, files, agents}`, for a
  few milliseconds when OpenCode is idle
  (`core/src/session/session.ts:149-170`). Enter submits a steer;
  `<leader>return` queues the prompt instead (`tui/src/config/keybind.ts:198`).
  A steer is promoted at the next step boundary, a queued prompt only when
  the turn ends (`core/src/session/inbox.ts:43-48`). Shell and slash prompts
  cannot be queued.
- The table holds pending items only. The row is deleted when OpenCode
  inserts its `user` row, which keeps the queue row's message id, or when it
  is cancelled. In capture A a prompt sent while a shell tool ran was queued
  324 ms after the send at `enqueued_seq` 184, waited 14 s, and became the
  user row at `seq` 187 with the same id.
- The TUI draws a waiting prompt at once, with a grey bar (`#484848`) where a
  delivered one has blue (`#5c9cf5`).
- The census store held two stale `synthetic` queue rows.
- In the in-app check each `!` command queued a `synthetic` note as it
  ended (`delivery` `steer`, `metadata.source` `shell`, its text the command
  and its output for the model), and the next prompt committed the waiting
  notes as `synthetic` rows before its `user` row.

## Identity

herdr 0.9.5 ships OpenCode's integration (`src/integration/assets/opencode/`):
a server plugin, which owns the lifecycle only for `opencode run` and the
minimal interface, and a TUI plugin. The TUI plugin reports the selected
root session through `pane.report_agent_session` with
`session_start_source: "select"`, polls the route every 100 ms and follows
`parentID` up to the root (`herdr-tui-session.js:10, 13-63, 424-438`). herdr
then shows `agent_session` as
`{source: "herdr:opencode", agent: "opencode", kind: "id", value: "ses_…"}`,
and accepts any non-empty id up to 512 bytes (`src/agent_resume.rs:5,
352-354`).

| Situation | What herdr reports |
| --- | --- |
| Start from a shell | `unknown`, then `idle` from herdr's screen manifest; no `agent_session` key and no `screen_detection_skipped` key |
| First prompt from the home screen | the session and its user row land first; herdr shows `working` with no session, then the id one 150 ms sample later, about 0.6 s after the prompt request. `screen_detection_skipped` is absent at 0.5 s and `true` by 1.5 s. In the in-app check (2026-10-21), prompts typed in the terminal got their id 0.3 to 0.4 s after Enter. On a freshly started Agent herdr's events read `working`, then `idle` 110 ms later as the id arrived, then `working` 100 ms after that; after `/new` the new id came while the old session still read `idle`, and `working` followed |
| `/new` or `/clear` | nothing: both go to the home screen, where the plugin reports nothing, so the old id and `done` stay until the first prompt of the new session |
| A session chosen in the picker | from `done`: its id within one 150 ms sample of OpenCode opening it (200 to 270 ms after Enter), `working` for about 150 ms, then `idle`. From `idle` (2026-10-21): its id 209 to 415 ms after Enter, once about 240 ms after the terminal title, and no status change |
| A subagent's view | the root id, unchanged; the status follows the root |
| Restart with `opencode --session <id>` | the id 368 ms after the launch, before any prompt; `idle`. Through `herdr agent start … -- -s <id>` in the in-app check, the id 1.6 s after the start request |
| Exit | `idle` with no session, then the Agent is gone (herdr's event reads `unknown`); OpenCode prints `Session   <title>` (no title for an untitled session) and `Continue  opencode -s <id>` as it exits (2026-10-21) |
| `opencode --continue` | in one sample, the root session OpenCode had open at exit, which was also the one viewed and updated last, not the one created last: its id with `idle` about 1.4 s after `herdr agent start … -- --continue`, before any prompt (2026-10-21). OpenCode's TUI asks for one root session of the directory in descending order **(source, `tui/src/app.tsx:655-680`)**; the column it orders by was not tested (F4) |

- OpenCode's terminal title (`tui/src/app.tsx:598-628`) is `OpenCode` on the
  home screen and for a session whose title is missing or a fallback title
  (`New session - ` or `Child session - ` and an ISO time,
  `util/src/session-title-fallback.ts:3, 25`). Otherwise it is `OC | ` and
  the title, cut to its first 37 UTF-16 units and `…` when longer than 40;
  `OC | ` and the route's name on a plugin route; and nothing at all while
  the `terminal.title` setting is off, so the pane keeps its last title.
  herdr shows it as `terminal_title`.
- OpenCode titles a session after its first exchange. The title alone cannot
  tell the home screen from an untitled session; the home screen's
  placeholder can (see [Screen](#screen)).
- Opening a running subagent (Down from an empty box opens the panel, then
  Enter) shows the child's conversation while herdr keeps the root id; Esc
  returns to the parent. Finished subagents cannot be opened by keys in
  2.0.32: the panel lists only running ones. In the in-app check the
  terminal title became the child's (`OC | ` and its description) within
  240 ms of Enter (the first `herdr agent get` read that showed it), and the
  parent's again on Esc.
- After `/new` in the in-app check, herdr kept the old id and changed only
  the terminal title, to `OpenCode`, within 150 ms of Enter. Chat's
  start-screen card first showed 1.0 to 1.5 s, 4.9 to 5.4 s and 6.9 to
  7.3 s after Enter (three samples).

## herdr status

| OpenCode | herdr status |
| --- | --- |
| Home screen, no session | `idle`, from the screen manifest |
| Prompt admitted, turn running | `working` |
| `idle` row written | `done`, with `completion_seq` |
| Permission or question pending | `blocked`, at most 325 ms after the tool reached `running` |
| After Allow once or an answer | `working`; the tool completed 26 ms after Enter. In the in-app check the read tool completed 5 ms after herdr logged the Allow once request and `working` came 115 ms after it; for a subagent's request, `working` came 175 ms after it (2026-10-21) |
| Reject, or Esc on a permission or a question | `blocked`, `working`, then `done`, with no `idle` row (Reject and Esc on a permission). In the in-app check, with the pane focused, a Reject and two question dismissals went `blocked`, `working` for about 210 ms, then `idle`, and OpenCode wrote no `idle` row (2026-10-21); `done` after a dismissed question was not observed |
| Esc stop | `done`, with `idle(interrupted)`. With a steer waiting, `idle` (the pane focused) for 105 ms, then `working` as the steer runs (two runs, 2026-10-21) |
| `/redo` | `working`, then `done` within about 200 ms; with the pane focused, `working` for 105 and 110 ms, then `idle` (2026-10-21) |
| `/undo` | unchanged |
| `/compact` | `working` while it compacts; for 110 ms when there was nothing to compact (2026-10-21) |
| A `!` command | unchanged; it runs in the background (2026-10-21) |
| A session chosen in the picker | from `done`, `working` for about 150 ms, then `idle`; from `idle`, unchanged, with no event (2026-10-21) |
| `/new`, before the first prompt | the previous session, still `done` |
| Restart with `--session` | `idle` with the id, then `done` after a turn |
| Provider failure (a refused connection, retried) | `working` through the retries, then `blocked` with no dialog on screen, 203 ms after the `idle(failed)` row (2026-10-21); the TUI plugin maps `execution.failed` to Blocked (`herdr-tui-session.js:581-583`) |

- Once the plugin has reported, it owns the status
  (`src/detect/mod.rs:330-340`). Before that, herdr's detection manifest
  (`src/detect/manifests/opencode.toml`) decides: Blocked on
  `△ Permission required`, or on `esc dismiss` with an `enter` action and
  `↑↓ select` or `⇆ tab`; Working on a run of four or more `■`/`⬝` cells, or
  on `esc interrupt` with `opencode` on the same line. The `[⋯]` footer drawn
  with animations off matches neither (F12).
- herdr's detection text matched the captured screen text in 61 of 69
  captures; the other 8 differed only in spinner frames.
- In the phone-width capture, with the pane focused, every turn end, root
  rejection, question dismissal and subagent rejection read `idle` with
  `completion_seq` set, never `done`: herdr counts a completion in its
  focused Tab as seen. The `done` rows above come from captures A and B.
  The in-app check, its pane focused throughout, never read `done` either.
  Of the twelve records it saved while the Agent was idle, the five whose
  last status change ended a turn had `completion_seq` equal to
  `state_change_seq`; the seven read after `herdr agent start` (`--continue`
  and `-s` included) and before any prompt, or after an idle pick in
  OpenCode's picker, had no `completion_seq`.
- herdr's events in the in-app check showed statuses that lasted 100 to
  110 ms: `working` for 105 and 110 ms on `/redo` and 110 ms on a
  `/compact` with nothing to compact; `idle` for 105 ms between a stopped
  step and the waiting steer that resumed (two runs); and, on a freshly
  started Agent's first prompt, `working` for 110 ms, then `idle` for
  100 ms as the session id arrived. Reading `herdr agent get` about every
  250 ms missed five of these seven.

## Screen

Captured at 180 columns by 47 rows in OpenCode's default dark theme. Text and
layout identify every state; colours change with the theme (F12) and here
only tell a typed draft from other text.

The input box sits at the bottom of a session's screen: rows that start with
`┃` (top padding, the input rows, padding, then the agent and model row),
then the box's lower edge `╹▀▀▀…`, then the footer. Popups sit above the box
with `┃` at both edges. Transcript blocks drawn with `┃` sit above a blank
row. A modal's title ends in `esc`, with no box edge under it.

| State | Text | Colour (default theme) |
| --- | --- | --- |
| Home | the logo, the input box's one row `Ask anything… "<example>"` (the example varies), the footer `shift+tab agents  ctrl+p commands`, and the version | |
| Session, empty box | `┃` rows with no placeholder (only the home route passes one, `tui/src/routes/home.tsx:102`); the agent row `Build · GPT-6 Astra OpenAI · high`; the footer `<cwd>:<branch>  <tokens> (<n>%)  ctrl+p commands` | bar `#5c9cf5`, box `#1e1e1e` |
| Draft | the text in the box | `#eeeeee` |
| Large paste | `[Pasted ~N lines]` in the box | |
| `/` popup, `@` popup | `/name  description` rows, or skills, agents and files, above the box | selected row background `#fab283` |
| Shell mode (`!` at the start) | agent row `Shell`; footer `esc exit shell mode` | label and bar `#fab283` |
| Working | the footer starts with eight `■`/`⬝` cells and `esc interrupt`; `↓ 1 shell` or `↓ 1 subagent` at its right while one runs | |
| Armed (one Esc) | `esc again to interrupt`, for 5 s | `#f5a742` |
| Permission | `△ Permission required`, `→ Read .env`, `Path: .env`, then `Allow once   Always allow   Reject` with `ctrl+f fullscreen  ⇆ select  enter confirm` at the right; the input box, agent row and footer are gone | focused option background `#fab283` with text `#0a0a0a`; the others on the panel's `#1e1e1e` |
| Question | `Questions`, the question, numbered options with their descriptions, `N. Type your own answer`, and the footer `↑↓ select  enter submit  esc dismiss` | focused option text `#fab283` |
| Session picker | `Sessions for <project>`, `esc`, `Today`; the footer `pin/unpin ctrl+f  delete ctrl+d  rename ctrl+r  all projects ctrl+a` | |
| Subagent panel | `Subagents  Shell  Terminals`, `General: <description>  Running`, and the footer `interrupt ctrl+d  show inactive ctrl+a  tabs ←/→`; no box edge | |
| Compaction | a `──── ⠋ Compaction ────` divider, its spinner frame changing, and the working footer; once failed, `──── ✗ Compaction ────` with the reason (`Nothing to compact yet`) under it (2026-10-21); once stopped, `──── Compaction · cancelled ────` in the muted colour, with no `✗` and no reason **(source, `tui/src/routes/session/index.tsx:2038-2073`)** | failed divider and `✗` `#e06c75`, the reason `#eeeeee` |
| Finished step | `Build · GPT-6 Astra · 13.8s · 0.4 tok/s`, with `· interrupted` after a stop, a rejection or a dismissed question; a dismissed question leaves `→ Asked 1 question` above it (2026-10-21) | |
| Retrying step (2026-10-21) | `⚠ Retrying in <n>s · attempt <n> · <error>` above the step's `Build · <model>` line (no duration yet), the seconds counting down, and the working footer | |
| Failed turn (2026-10-21) | `Error: <error>` above `Build · <model> · <duration>`, the box empty and no dialog; a `Session failed` toast with the error and an `x` covered the top rows in the captures 1 to 5 s after the failure | |

- The permission dialog's text is the same whichever option has focus; only
  the colours show it. Always allow is offered only when the request can be
  saved (`tui/src/routes/session/permission.tsx:232-240`); the option labels
  are in `tui/src/util/permission.ts:162-168`. While it has focus, the rows
  between the `→` row and the options show its always-allow lines ("This will
  always allow read for this project.") in place of the notes such as
  `Path: .env` (`tui/src/routes/session/permission.tsx:223-231`).
- A subagent's permission or question is drawn in the root session's view,
  which lists its descendants' requests
  (`tui/src/routes/session/index.tsx:198-214`). A subagent's own view lists
  no permissions and only global forms, and shows the subagent panel in place
  of the input box unless a global form is pending
  (`routes/session/index.tsx:202-214, 1469, 1483`), so a request raised while
  the user watches a subagent shows no dialog there **(source)**. In the
  in-app check a subagent's read permission was drawn in the root's view as a
  root request is, below the running subagent's line (`⠦ General Subagent`
  and its description) and `Press ctrl+b to move running work to the
  background` (2026-10-21).
- At 62 columns by 41 rows (the phone-width capture) the same text and
  layout identify every state. In that capture the working footer cut
  `esc interrupt` to `esc...rupt` and joined it to the progress bar
  (`⬝⬝⬝⬝⬝⬝⬝esc...rupt  ↓ 1 shell · 9.4K (2%)  ctrl+p commands`, stem 35),
  so only the bar marked a running turn; the in-app check saw that cut only
  while the token count read under 10K (below). The armed footer keeps
  `esc again to interrupt` whole (stem 36), and the queued-prompt dock
  keeps the cut hint (stem 43). The footer's directory is shortened segment
  by segment on the home screen and a session (`/…/t…/<dir>/project:main`)
  and shown whole in shell mode. The home screen keeps its logo's top row
  and the muted `Ask anything… "` prefix, its example cut at the edge.
- At that width a permission's key hints take their own row below the
  options (stem 37), and long targets, questions and answers wrap inside the
  bar, an answer's continuation rows indented under its label (stem 38); the
  question footer stays `↑↓ select  enter submit  esc dismiss`. The `/`
  popup sits directly on the box with no blank row between (stem 39), and
  the subagent panel shows `Subagents  Shell  Terminals` with `esc` at its
  right, a `General: <description>  Running` row and no box edge (stem 41).
- In the in-app check at the same size (2026-10-21) the footer's right part
  went with the token count in every capture. Under 10K (`9.5K` to `9.9K`)
  the footer kept `ctrl+p commands` and made room for it: idle, it
  shortened the directory
  (`/…/t…/<dir>/project:main  9.8K (2%)  ctrl+p commands`); working, it cut
  the hint (`⬝⬝⬝⬝⬝esc...upt  ↓ 1 subagent · 9.8K (2%)  ctrl+p commands`,
  the one such capture). From `10.0K` up it dropped `ctrl+p commands` and
  showed `esc interrupt` whole beside the count, `↓ 1 shell` or
  `↓ 1 subagent`; an idle session's directory was whole beside the count,
  and shortened only beside `↓ 1 shell · 10.2K (3%)` while a `!` command
  ran. With no count (after a compaction, in a session whose only step
  failed, and on the home screen) the footer read
  `shift+tab agents  ctrl+p commands` beside a shortened directory or the
  hint, or `esc exit shell mode` in shell mode; two reads just after a Stop
  that followed an armed Esc showed the directory alone. The bar started
  every working footer. The armed footer read `esc again to interrupt` with
  no token count.

## Keys

| Action | Keys |
| --- | --- |
| Interrupt | Esc twice within 5 s; the first only arms (`tui/src/component/prompt/index.tsx:499-530`). Two Esc 337 ms apart, two 3.19 s apart, and one `agent.send_keys` request with `esc esc` all interrupted; after the single request the tool was aborted 22 ms later. In the in-app check each of the eight Stops Chat sent was one such request, and `idle(interrupted)` came 15 to 21 ms after herdr logged it; the two Stops Chat refused (a `/` popup open, shell mode) sent nothing. When an Esc typed in the terminal had already armed the interrupt, the request's first Esc interrupted and its second changed nothing (two runs, 2026-10-21) |
| Allow once | Enter; Allow once is preselected |
| Always allow | Right, then Enter, when offered |
| Reject a root session's request | Right until Reject has focus (twice when Always allow is offered, else once), then Enter; or Esc |
| Reject a subagent's request | Esc or Reject opens `△ Reject permission`, "Tell OpenCode what to do differently", with `enter confirm  esc cancel` (Esc observed in the phone-width capture, stems 25 and 42); Enter sends the feedback, Esc goes back **(source, `permission.tsx:248-252, 272-405`; F3)** |
| Answer a single-select question | the option's digit, which selects and submits |
| Custom answer, multi-select | the digit of `Type your own answer`, the text and Enter; Space toggles an option **(source, `tui/src/routes/session/form.tsx:570-760`; F11)** |
| Dismiss a question | Esc (2026-10-21; its rows under [Turns](#turns)) |
| Switch the agent | `shift+tab`, from Build to Plan and back; `tab` changed nothing (2026-10-21) |

- `ctrl+c` clears a non-empty input and exits OpenCode from an empty one
  (`prompt/index.tsx:952-958`); in a dialog it rejects or dismisses.
- Esc does nothing while a popup shows or the input is unfocused, and in
  shell mode it only leaves shell mode (`prompt/index.tsx:506-512`). A mouse
  selection in the terminal takes the next Esc
  (`tui/src/util/selection.ts:89`) **(source)**.
- The interrupt resumes. OpenCode interrupts with `resume: true`, and a
  waiting steer, compaction or move then wakes a new execution; prompts
  queued for the next turn stay queued
  (`core/src/session/execution.ts:153-168`) **(source)**. The in-app check
  saw it with a waiting steer: the steer's `user` row came 4 to 6 ms after
  `idle(interrupted)` and ran until its own `idle` row (three runs:
  `succeeded` twice, and `interrupted` once when a second Stop ended the
  resumed run, 2026-10-21).
- Up recalls the last prompt into an empty box, and Down opens the subagent
  panel. Enter on an empty box steers the first queued prompt
  (`prompt/index.tsx:1297-1305`, `routes/session/index.tsx:1522-1526`;
  **source**). `ctrl+u` clears a one-line draft. In the phone-width capture,
  Down on an empty box opened the panel while a subagent ran, and Esc closed
  it without arming the interrupt. In the in-app check Up left the cursor at
  the start of the recalled prompt, so `ctrl+u` alone removed nothing;
  `right` pressed to its end, then `ctrl+u`, emptied the box (2026-10-21).

## Sending

- herdr's `agent.prompt` refuses a Blocked Agent only while validating the
  request (herdr `src/app/api/agents.rs:168-177`). It then pastes the text and
  writes Enter 300 ms later (`:13`, `:260-266`; `src/pty/actor.rs:117-153`),
  so a dialog that appears in between takes the Enter. The user row landed
  329 to 367 ms after the request. In the in-app check it landed 319 to
  341 ms after the request over 13 sends, and herdr's log completed each
  request about 300 ms after it started (2026-10-21).
- OpenCode first tries pasted text as a file path: a path to an image, PDF or
  SVG becomes an attachment (`tui/src/component/prompt/local-attachment.ts:29-47`)
  **(source)**. Otherwise text of 3 or more lines or over 150 characters
  shows `[Pasted ~N lines]` 38 to 55 ms after the paste and is stored trimmed,
  plus one space; shorter text is inserted and stored as sent, a trailing
  space included. herdr's Enter submitted both kinds in every capture.
- A typed space closes the `/` and `@` popups. `/compact ` with a space went
  to the model as an ordinary prompt and compacted nothing; `/new ` did the
  same. `/compact` alone opened the popup with `/compact` first, and herdr's
  Enter ran it. Enter in a popup runs its top fuzzy match
  (`tui/src/component/prompt/autocomplete.tsx:548-571`). In the in-app
  check a custom command `compact-notes` in the project's
  `.opencode/commands/` was listed at once, with no restart, but second:
  `/compact  Compact session` stayed first, and herdr's Enter ran the
  built-in both times (a failed compaction with nothing to compact, then a
  completed one), with no `user` row holding the command's template
  (2026-10-21).
- Of the TUI's own commands only `btw`, `cd` and `rename` take arguments.
  Server commands (`init`, `review`, custom commands from the config or from
  `command` and `commands` folders, MCP prompts) need `/name args ` with the
  space, and their user row holds the expanded template **(source; F13)**.
  OpenCode sends an unknown `/name text` as an ordinary prompt. Skills have no
  text syntax: a prompt carries them as attachments.
- A whole input of `exit`, `quit` or `:q`, trimmed and case-sensitive, exits
  the TUI (`prompt/index.tsx:1124, 1140-1143`). `!` at the start enters shell
  mode.
- `/undo` and Up leave a prompt in the box, and herdr's paste appends to it:
  after `/undo`, capture B stored "Reply with exactly: three.Reply with
  exactly: four." as one message.
- `@README.md ` typed with a trailing space opened no popup and stayed text
  (`files: []`). Files attach only through the popup or a pasted path.
- A prompt sent while OpenCode works is steered through the queue, never
  refused.
- OpenCode 2.0.32's default permissions allow everything except reading
  `*.env` and `*.env.*` files other than `*.env.example`
  (`schema/src/agent.ts:46-51`), so shell commands and edits did not ask in
  the captures; reads of dummy `.env` files raised the permission dialogs.

## Costs

- **Bench**, on the census store's largest session by data (128 rows,
  5.5 MB of `data`), while the background service held the store: every plan
  was an index search. All rows in order took 12.3 ms (6.07 MB as `-json`),
  rows after a `seq` 0.26 ms, rows changed since a time 0.34 ms, the newest
  20 rows 0.79 ms, the counter 0.30 ms, a count, maximum and size fingerprint
  3.2 ms, the session row 0.22 ms, the queue 0.28 ms, and open assistant rows
  through `json_extract` 6.4 ms.
- **Live reads.** Capture A spawned one `/usr/bin/sqlite3 -readonly` per poll
  over three sessions and up to 60 rows: 869 timed polls took min 5.2, p50
  8.1, p95 12.3, p99 18.0 and max 41.1 ms, the spawn included.
- **Bytes.** The census's 6,481 rows hold 70.8 MB of `data`. Tool output
  text is 40.2% of it; diagnostics 13.8%; whole-file before and after copies
  9.4%; encrypted reasoning 4.6%; previews 3.0%; a second copy of the output
  2.3%; `metadata.diff` 1.4%; and snapshot file lists 1.1%. Dropping all but
  the output and the diff removes 34.3%. Rows measure median 3,923 B, p95
  44,656 B and max 696,782 B; slimmed of those fields, median 2,836 B, p95
  27,253 B and max 252,426 B.
- `sqlite3 -json` (3.33 and later) prints each statement's result as one
  JSON array whose text columns are JSON strings, so `data` comes encoded
  twice, and prints nothing at all for an empty result.
- **In-app polls** (2026-10-21), through the isolated `sshd` on the
  development Mac over loopback, with a wrapper timing each exec on the Host
  side: Chat's store query took p50 51, p95 58 and max 103 ms over 497
  polls in one batch, and p50 49, p95 54 and max 57 ms over 122 in another,
  every exit status 0; its script was 14,099 to 14,716 bytes. In the
  497-poll batch the Changes probe took p50 135 ms and plain execs p50 32 ms
  on that connection (126 and 30 ms over 2 and 4 execs in the other). Polls
  started 3.6 to 4.7 s apart while idle and 1.5 to 2.6 s apart while
  working or lingering (p50 of all gaps 4.2 s); a few came sooner, right
  after a send, a Stop or a return to Chat.
- Each query used p50 17.2 ms (max 20.5) of CPU in its shell, `sqlite3`
  and watchdog, plus p50 15.0 ms in the exec's own login shell and the
  wrapper. A trivial exec through the same chain took 5 ms, with 3.9 ms of
  CPU in its children and 13.4 ms in its own process, so the query adds
  about 13 ms of CPU in its children (15 ms counting its own processes) and
  44 ms of wall time. Over 425 s with Chat showing, the queries used 0.49%
  of one core (0.94% with the execs' own processes); the connection's
  `sshd` process used 0.03% over the 456 s that `ps` sampled it.
- In the second batch no query overlapped another exec, and none ran while
  the terminal was shown; Attach's PTY exec started 190 to 430 ms after the
  tap, and each screenshot of the terminal matched herdr's own read of the
  pane at that moment. With the connection's `sshd` process stopped for
  15 s, Chat showed its timeout at the 10 s deadline; the waiting query
  reached the Host 35 ms after the process resumed, and the next poll, 8.4 s
  after the deadline (the idle pace doubled once), read normally on the same
  connection.
- Not measured: the round trip Chat sees for a query, over loopback or a
  slower link (the wrapper timed only the Host side), and whether polling
  delays the Events channel (F15).

## Host tools

On the development Mac, with the PATH Heeler's execs use, `sqlite3` resolved
to `/usr/bin/sqlite3` (3.54.0) and `python3` to Homebrew's (3.14.6);
`opencode` was not on that PATH. `/usr/bin/python3` (3.9.6) works there only
because Xcode is installed: without the Command Line Tools it only offers to
install them.

Which tools Linux images carry by default is not measured (F14); the Debian,
Fedora and Arch rows are the least certain. The system SQLite of Rocky 8,
Ubuntu 20.04 and Debian 12 was confirmed in containers (below):

| Host | `sqlite3` CLI by default | System SQLite | `python3` by default |
| --- | --- | --- | --- |
| Ubuntu 24.04, 22.04 | no | 3.45.1, 3.37.2 | yes |
| Ubuntu 20.04 | no | 3.31.1 | yes (3.8) |
| Debian 12, 11 | no | 3.40.1, 3.34.1 | in cloud images; a minimal install may lack it |
| Fedora 40 and later | no | 3.4x | yes |
| RHEL, Alma and Rocky 9 | no | 3.34.1 | yes (3.9) |
| RHEL, Alma and Rocky 8 | no | 3.26.0 | no `python3` command; only `/usr/libexec/platform-python` 3.6 |
| Arch | when `python` is installed, through its `sqlite` dependency | current | not in `base` |
| Alpine, minimal containers | no | | no |

SQLite before 3.46 parses on a fixed stack of 100 entries and fails a
statement nested deeper with "parser stack overflow". Chat's statements need
at most 57, measured with the parser-depth limit of SQLite 3.53. In
containers they printed the same output for 320 queries over the store
fixtures on SQLite 3.26.0 (Rocky 8, through Python 3.6), 3.31.1
(Ubuntu 20.04), 3.40.1 (Debian 12) and 3.53.3.

## Open items

Numbered as in the evidence pass. Results go into the sections above as they
are verified, and an answered item leaves this list.

- **F1.** Whether a rejected turn resumes when OpenCode's background service
  restarts. Testing it restarts the user's service.
- **F3.** A subagent's reject-feedback stage: its rows, herdr's status once
  a non-empty message is sent, and whether the root turn then ends with an
  `idle` row. The phone-width capture confirmed the stage with an empty
  message (herdr read `working`, then `idle` with `completion_seq` set, and
  the root turn went on to a reply) but read no rows; the in-app check
  allowed a subagent's request but never entered the stage.
- **F4.** Which root session `opencode --continue` picks when the one open
  at exit, the one viewed last and the one updated last differ.
- **F5.** A provider error other than a refused connection (the census's
  `provider.error`): whether OpenCode retries it, its rows, herdr's status
  and the screen.
- **F6.** Rows for switching the model.
- **F9.** A background subagent's completion row, and whether it starts a new
  turn.
- **F10.** Automatic compaction, and where its turn's `idle` row lands.
- **F11.** Custom answers and multi-select questions.
- **F12.** (b) Other themes' colours; (c) the footer with animations off;
  (d) the box after a paste with `prompt.paste=full`; (e) the queued-prompt
  indicator.
- **F13.** Server commands sent through `agent.prompt`.
- **F14.** On Linux: which readers common images carry by default.
- **F15.** The round trip Chat sees for a query, over loopback and over a
  slower link, and whether Chat's polling delays the Events channel.
