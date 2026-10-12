# Codex rollout format

Observed on 2026-10-06. The cited source is Codex `rust-v0.160.1`, the
release that wrote the probe rollouts (CLI 0.160.1). herdr was 0.9.3
(protocol 22).

This note records the rollout files that native Chat reads for Codex: the
two dialects, which records carry the conversation, how turns, reverts and
tool calls appear, and what a reader can rely on while Codex is still
writing.

## Evidence and provenance

Citations such as `probe2-rollout.jsonl:10` name a file in
`Tests/HeelerTests/ChatFixtures/codex/` and a 1-based line; a following `:11`
is another line of the same file. The probes ran against an isolated herdr
backend. Scrubbing kept every byte offset and line number (see the fixtures
README), but the probe tooling re-serialized each line, so the fixtures are
not byte-identical to the compact JSON Codex writes.

| Source | Version | Cited as |
| --- | --- | --- |
| First probe rollout | Codex 0.160.1, paginated, 65 lines | `probe1-rollout.jsonl` |
| Second probe rollout | Codex 0.160.1, paginated, 119 lines, ordinals 0 to 118 | `probe2-rollout.jsonl` |
| Codex source | `openai/codex` tag `rust-v0.160.1` (`d27764b8`) | `codex-rs/<path>:<lines>` |
| Codex upstream main | `822e58cc` (2026-10-06) | "upstream main" |
| Older Codex | single files at tags `rust-v0.30.0` and `rust-v0.45.0` | the tag is named |
| herdr | v0.9.3 (`7b116c05`) | herdr `src/<path>:<lines>` |
| Local scan | a structure-only scan of 7,668 rollouts on one development machine, 2026-10-06 | aggregate counts only |

Two files recur and are cited by name alone: `protocol.rs` is
`codex-rs/protocol/src/protocol.rs`, and `thread_history.rs` is
`codex-rs/app-server-protocol/src/protocol/thread_history.rs`.

Statements without a label were checked against source or fixtures. **Not
verified** marks statements reasoned from source but not observed;
[Not verified](#not-verified) collects them.

## Envelope and dialects

Every line is one record:
`{"timestamp":"…Z","ordinal":0,"type":"session_meta","payload":{…}}`.

- `RolloutLine {timestamp, ordinal: Option<u64>, #[flatten] item}`
  (`codex-rs/history/src/lib.rs:349-356`).
- `type` is snake_case and the body is in `payload`. A `response_item` may
  also carry `metadata` (`codex-rs/history/src/rollout_payload.rs:31-72`).
- Decoding requires an object with `timestamp`; `ordinal` may be absent or
  null (`codex-rs/rollout/src/lib.rs:52-74`).

The top-level types (`codex-rs/history/src/lib.rs:199-217`) are
`session_meta`, `response_item`, `event_msg`, `compacted`, `turn_context`,
`world_state`, `retained_context`, `token_usage_record`,
`security_risk_score`, `inter_agent_communication`,
`inter_agent_communication_metadata` and `realtime_item`.

### Writer

- `session_meta` is always the first line.
- Each record is compact `serde_json::to_string` output plus `\n`, written
  with `write_all` and `flush` and no fsync
  (`codex-rs/rollout/src/recorder.rs:2057-2097`).
- On reopening a file, the writer appends `\n` if the file does not already
  end with one (`codex-rs/rollout/src/recorder.rs:2042-2055`).
- JSON escapes control characters, so a raw 0x0A byte only ever ends a
  record.

### Dialect detection

Line 1 alone decides how to read a rollout:

1. Line 1 must have the `type` `session_meta`. An object with `id` and
   `instructions` but no `type` is the pre-envelope format of Codex 0.30 and
   older. Anything else is not a rollout.
2. `payload.history_mode` `paginated` means the paginated dialect. An absent
   value or `legacy` means the legacy dialect. Codex rejects any other value
   (`protocol.rs:775-803`).
3. A `.jsonl.zst` file is compressed.

| | Paginated | Legacy |
| --- | --- | --- |
| `ordinal` | On every line, contiguous | Absent |
| Visible messages | `item_completed` `UserMessage` and `AgentMessage` | `user_message` and `agent_message` events |
| Tool calls | Turn items | Response items paired by `call_id`, plus `*_end` events |
| Compaction marker | `ContextCompaction` item | `context_compacted` event |
| Undo | A revert writes a new file with `history_base` | `thread_rolled_back{num_turns}` |
| Message identity | `turn_id` and `item.id` | Nothing beyond the line's byte offset |
| `item_completed` written for | Every turn item | Only `FunctionCallOutput`, `Plan`, `Extension(clock.sleep)` and `SubAgentActivity(completed)` |

The persistence policy is `codex-rs/rollout/src/policy.rs:10-206`. These are
never written: `exec_command_end`, `item_started`, deltas, approval requests,
`request_user_input` events, `plan_update`, `error` and `warning`.

All 7,668 rollouts in the local scan are paginated, so the legacy rules rest
on source reading only (Not verified against real files).

## Record types

| Record | Carries | Notes |
| --- | --- | --- |
| `session_meta`, line 1 | The segment header | `id`, `session_id`, `cwd`, `cli_version`, `history_mode`, `history_base?`, `forked_from_id?`, `subagent_history_start_ordinal?` (`protocol.rs:3123-3270`). Later `session_meta` lines can be ignored. |
| `task_started`, `turn_started` | A turn's start | Opens turn `turn_id`. The legacy builder finishes the current turn first (`thread_history.rs:1292-1302`). |
| `task_complete`, `turn_complete` | A turn's end | `failed` when `error: ErrorEvent{message}` is set, else `completed` (`protocol.rs:2152-2176`). The first terminal state wins, and a turn never opened is created. |
| `turn_aborted` | A turn's end | Needs `turn_id`. `reason` is `interrupted`, `budget_limited`, `replaced` or `review_ended`. Without an id, the paginated projection ignores it and the legacy builder applies it to the current turn (`thread_history.rs:1254-1290`). |
| `item_completed` | A turn item | Payload `{type, thread_id, turn_id, item, started_at_ms?, completed_at_ms}` (`protocol.rs:1947-1964`); see [Turn items](#turn-items). |
| Legacy `user_message` | A user message | Text only; skill parts are dropped (`codex-rs/protocol/src/legacy_events.rs:75-138`). |
| Legacy `agent_message` | An assistant message | Empty ones are skipped (`thread_history.rs:522-536`). |
| Legacy `agent_reasoning` | Reasoning | Appends to the previous reasoning (`thread_history.rs:538-616`). |
| Legacy `context_compacted` | A compaction marker | |
| `thread_rolled_back` | An undo | Legacy only; see [Legacy turns](#legacy-turns). The paginated projection ignores it. |
| Legacy `patch_apply_end`, `mcp_tool_call_end`, `web_search_end`, `image_generation_end`, `sub_agent_activity`, review events | Tool and activity results | |
| `token_count`, `thread_settings_applied`, `thread_goal_updated`, unknown events | Nothing to show | |
| `response_item` | Model input | Never a message. Paginated rollouts use it only for question details ([Questions](#questions)); legacy rollouts carry tool calls in it ([Legacy pairing](#legacy-pairing)). A user response item starting `<hook_prompt hook_run_id=` is a hook prompt (`thread_history.rs:477-501`). |
| `retained_context` `verified_answer` | Answered questions | `{turn_id, call_id, questions: [{question, answer}]}` (`codex-rs/history/src/retained_context.rs:144-161`) |
| `compacted` | Model context | A non-empty `message` becomes model-side context (`codex-rs/history/src/lib.rs:274-343`). |
| Everything else | Nothing to show | |

### Turn items

`item.type` is PascalCase (`codex-rs/protocol/src/items.rs:42-78`).

| Item | Fields | Meaning |
| --- | --- | --- |
| `UserMessage` | `id`, `client_id?`, `content: [UserInput]` | A user message, or an answer to an async question ([User message display](#user-message-display)) |
| `AgentMessage` | `content: [{type: "Text", text}]`, `phase?`, `delivery?`, `questions?` | Assistant text, skipped when empty; with async questions it asks them ([Questions](#questions)) |
| `Reasoning` | `summary_text: [String]` | A reasoning summary, skipped when empty |
| `Plan` | `id` (`<turn_id>-plan`), `text` | The plan (`codex-rs/core/src/session/turn.rs:1966-2020`) |
| `ContextCompaction` | `id` | A compaction marker |
| `HookPrompt` | `fragments: [{text, hookRunId}]` | A hook's prompt |
| `CommandExecution`, `FileChange`, `McpToolCall` | See [Tool calls and outputs](#tool-calls-and-outputs) | Tool calls |
| `WebSearch`, `Extension` (`kind` `image_gen.generation`, `clock.sleep` or `web.search`; `codex-rs/ext/items/src/lib.rs:35-45`), `DynamicToolCall`, `FunctionCallOutput` | Title fields, `status` | Activity |
| `ImageView`, `ImageGeneration` | `path`; `revised_prompt?` | An image; `result` can be large and needs no decoding to show the item |
| `CollabAgentToolCall`, `SubAgentActivity` | `tool`, `status`; `kind`, `agent_path` | Subagent activity |
| `EnteredReviewMode`, `ExitedReviewMode` | `user_facing_hint`; `review_output?` | Review mode changes |
| Unknown | | Ignored |

Phases are `commentary` and `final_answer`; upstream main adds
`partial_answer` (`codex-rs/protocol/src/models.rs:927-952`). Any phase reads
as assistant text.

## Thread identity

The file name is
`$CODEX_HOME/sessions/YYYY/MM/DD/rollout-YYYY-MM-DDThh-mm-ss-<threadID>[_<rolloutID>].jsonl`.

- The directory and the name use the host's local time
  (`codex-rs/rollout/src/recorder.rs:1722-1744`). Archiving moves a file
  unchanged into the flat `archived_sessions/` directory
  (`codex-rs/rollout/src/lib.rs:86-87`).
- Parsing (`codex-rs/rollout/src/rollout_file_name.rs:39-74`): strip `.zst`,
  `rollout-` and `.jsonl`. The next 19 characters are an opaque, sortable
  timestamp key, followed by `-`. The rest splits at the first `_` into the
  thread id and the rollout id; without `_`, the two are equal.

Inside the file:

- `session_meta.payload.id` is the thread id. It stays the same across
  reverts.
- `session_id` is the root thread id. It differs for subagents and, when
  missing, is filled from `id` (`protocol.rs:3235-3270`).
- `item_completed.payload.thread_id` and
  `thread_settings_applied.payload.thread_id` equal the thread id (21 of 21
  and 7 of 7 in `probe2-rollout.jsonl`).
- `history_base.thread_id` is a base **rollout** id, despite its name
  (`protocol.rs:3101-3115`).

herdr reports a Codex agent's session as
`agent_session {source: "herdr:codex", agent: "codex", kind: "id", value}`,
without a path.

- The value is the `session_id` that Codex passes to its `SessionStart` hook
  (herdr `src/integration/assets/codex/herdr-agent-state.sh:51-80`), which is
  the session's id and so the root thread id
  (`codex-rs/core/src/hook_runtime.rs:155-156`). herdr keeps a path only for
  `pi` and `omp` (herdr `src/agent_resume.rs:116-133`).
- Finding the rollout therefore means listing the date directories within a
  day of the time in the UUIDv7 id, picking the newest
  `(timestamp key, rollout id)` as Codex does
  (`codex-rs/rollout/src/list.rs:1579-1608`), and checking
  `session_meta.payload.id`.

## Messages and deduplication

- **Paginated.** A message is exactly one `item_completed` carrying a
  `UserMessage` or `AgentMessage`, identified by the rollout id, `turn_id`
  and `item.id`. Its position comes from the first accepted ordinal and its
  content from the latest snapshot
  (`codex-rs/thread-store/src/local/thread_history_materialization.rs:123-310`).
- **Legacy.** Each `user_message` line and each non-empty `agent_message`
  line is one message, identified only by its byte offset.
- **Repeats are real.** In the local scan, 344 prompts exactly repeat the
  previous prompt, so text never deduplicates messages.
- **Response items are not messages.** They duplicate items
  (`probe2-rollout.jsonl:9` and `:10`, `:11` and `:12`, `:18` and `:19`), and
  their ids differ from the item ids, so the two cannot be linked. Contextual
  response items (`<environment_context>`, `<skill>`, `<turn_aborted>`,
  AGENTS.md) have no item at all.

### Paginated ordinals

- A line without an ordinal is skipped.
- An ordinal at or below the last accepted one is skipped, so the first line
  with an ordinal wins. 2 files in the local scan repeat an ordinal.
- A gap is worth a diagnostic, nothing more.
- Ordinals below `session_meta`'s `subagent_history_start_ordinal` are
  skipped.

### User message display

The TUI renders a `UserMessage` like this
(`codex-rs/tui/src/chatwidget/user_messages.rs:702-851`):

1. Join the `text` parts with no separator
   (`codex-rs/protocol/src/items.rs:543-552`). `local_image` and `image`
   parts are attachments, while a typed `[Image #N]` stays in the text.
   `skill` and `mention` parts are hidden. Other parts are generic
   attachments (`codex-rs/protocol/src/user_input.rs:12-57`).
2. An answer to an async question is not a message
   (`codex-rs/tui/src/async_question_reply.rs:15-47`). Trim the text and drop
   an optional IDE prefix (`# Context from my IDE setup:\n` up to
   `\n## My request for Codex:\n`). What remains must be exactly
   `<send_user_message_question_reply>JSON</send_user_message_question_reply>`,
   where JSON is an array or object of `{questionItemId, question, answer}`.
   Ids over 512 characters fall back to plain `> q\n\na` text, which reads as
   an ordinary message (`codex-rs/context-fragments/src/answered_question.rs`).
3. IDE preamble: if the text contains `## My request for Codex:`, the
   message is the trimmed text after the last marker, and the preamble before
   it is context (`codex-rs/tui/src/ide_context/prompt.rs:16-74`).
4. Skill prompts: see [Skills and /compact](#skills-and-compact).

### Agent messages

Join the `Text` parts; an empty result is skipped
(`probe2-rollout.jsonl:84`). In plan mode an empty final answer produces no
item at all, and `probe2-rollout.jsonl:50` is only a response item
(`codex-rs/core/src/session/turn.rs:2346-2388`).

### Questions

Async questions (`probe2-rollout.jsonl:65`) are an `AgentMessage` with
`delivery: "async"` and `questions: [{title, options?}]`. Its item id is the
tool call's `call_…` id, and it has no response-item twin.

- Question *i* has the id `["request_user_input_async","<item id>",i]` as a
  JSON string (`codex-rs/tui/src/bottom_pane/async_questions/state.rs:18`).
- It is answered when a later reply carries that id, or the bare item id
  from older desktop clients
  (`codex-rs/tui/src/bottom_pane/async_questions/state.rs:147-155`).
- `probe2-rollout.jsonl:78` answers only index 0, so the second question
  ("Pick a drink") stays open.

Sync `request_user_input`:

- `retained_context` `verified_answer` holds the answers
  (`probe2-rollout.jsonl:47`). Its `question` can carry more lines after the
  question itself (`Pick a color\nRed: Choose red.`).
- Without it, pair the `function_call` arguments
  `{questions: [{id, header, question, options}]}`
  (`probe2-rollout.jsonl:45`) with the `function_call_output`
  `{"answers": {"<id>": {"answers": [...]}}}` (`:48`) by `call_id`. A typed
  answer is an extra `user_note: ...` entry (`:48` has `None of the above`
  and `user_note: Medium please`).
- What a declined question writes is Not verified.

## Turns, rollback and compaction

### Paginated turns

The app server projects a paginated rollout like this
(`codex-rs/app-server-protocol/src/protocol/thread_history_projection.rs:21-100`):

- `task_started` opens a turn, `task_complete` completes or fails it, and
  `turn_aborted` with an id interrupts it.
- `item_completed` adds or replaces an item in its turn. Every other record
  is ignored, including `thread_rolled_back`.
- Late items stay in their turn: `probe2-rollout.jsonl:36` arrives after the
  abort at `:35`, and `probe1-rollout.jsonl:21` after the output of the cell
  that ran it.
- Turns sort by their first ordinal.

When a thread is not running, the app server marks every turn still in
progress as interrupted
(`codex-rs/app-server/src/request_processors/thread_lifecycle.rs:919-933`).
The file alone cannot say whether a turn is still running: only the newest
open turn can be, and herdr's agent status (Working) is the live signal.

### Revert

A paginated undo (revert) writes a new file, `…-<thread>_<newRollout>.jsonl`,
whose `session_meta` carries `history_base` with `thread_id` (the base
rollout id), `end_ordinal_exclusive` and `end_byte_offset`. Older files are
untouched (`codex-rs/thread-store/src/local/revert_thread.rs:15-150`; the
TUI's backtrack is `codex-rs/tui/src/app/event_dispatch.rs:684-768`).

- Read the base over `[0, end_byte_offset)`. The byte before the end must be
  `\n` and the last ordinal must be `end_ordinal_exclusive - 1`; otherwise
  the history before the revert is unavailable.
- Read the new file from `end_ordinal_exclusive`, and take each turn's
  status from the newest segment
  (`codex-rs/thread-store/src/local/rollout_lineage.rs:14-189`).
- Turns that were rolled back are simply absent.
- The thread id does not change, so herdr's reported id stays the same while
  the live file becomes the newer `_<rolloutID>` sibling.

### Legacy turns

Codex's `ThreadHistoryBuilder` (`thread_history.rs`) rebuilds legacy turns:

- A `user_message` closes an implicit turn unless that turn holds only a
  compaction (`thread_history.rs:503-520`).
- `thread_rolled_back{num_turns}` finishes the current turn and drops the
  last N turns of any kind (`thread_history.rs:1370-1394`). It applies on
  replay and live, so a live rollback removes turns already shown.
- Empty implicit turns are dropped (`thread_history.rs:1396-1403`).
- A completion applies to the current turn when the ids match, else to an
  earlier turn with that id, else to the current turn
  (`thread_history.rs:1304-1359`).
- Implicit turns get ids `rollout-<lineIndex>`
  (`thread_history.rs:1405-1427`). They depend on where reading started, so a
  reader that starts mid-file cannot reproduce them.

### Compaction

Compaction never removes history from the file. A `ContextCompaction` item
(paginated) or a `context_compacted` event (legacy) marks the point, and
automatic compaction writes the same item inside an ordinary turn.

## Tool calls and outputs

In a paginated rollout, tool calls appear only as turn items.

### Code-mode cells

- Code-mode `exec` cells (`probe2-rollout.jsonl:13`, `:30`, `:109`), whose
  JavaScript input calls tools such as `tools.exec_command({cmd: …})`, are
  response items, not tool calls of their own. So are their outputs
  (`probe2-rollout.jsonl:16`: `Script completed\nWall time…\nOutput:\n`
  followed by JSON).
- One cell can run several commands (`probe2-rollout.jsonl:109` leads to
  `:111` and `:112`).
- A command can complete after its cell's output
  (`probe1-rollout.jsonl:21`).
- An aborted cell's output is `aborted by user after <seconds>s`
  (`probe2-rollout.jsonl:32` says 9.7s, `:98` 9.6s). A command it never
  started has no item (`probe2-rollout.jsonl:96-101`), while a patch it
  started still completes as a failed `FileChange` (`:36`).

### Command executions

`CommandExecution` (`codex-rs/protocol/src/items.rs:243-290`):

- **Title.** For `[sh|bash|zsh, "-lc"|"-c", script]` the TUI shows `script`,
  and otherwise the shell-joined argv
  (`codex-rs/shell-command/src/bash.rs:106-118`,
  `codex-rs/tui/src/exec_command.rs:12-17`). `parsed_cmd` (`read`,
  `list_files`, `search`, `unknown{cmd}`) can relabel it.
- **Status.** `completed`, `failed`, `declined` or `in_progress`. Unified exec
  reports `completed` exactly when the exit code is 0
  (`codex-rs/core/src/tools/events.rs:532-550`).
- **Fields.** `exit_code`; `duration` as `{secs, nanos}`; `source` (`agent`,
  `user_shell` or `unified_exec_*`); and `cwd`, a `file://` URI
  (`codex-rs/utils/path-uri/src/lib.rs:59-67`), although plain paths should
  be accepted too.
- **Output.** Unified exec fills `aggregated_output` from the session
  transcript and copies it into `stdout`
  (`codex-rs/core/src/unified_exec/async_watcher.rs:331-380`). Every command
  output in the fixtures is empty.

### File changes

`FileChange.changes` maps each path to `add{content}`, `delete{content}` or
`update{unified_diff, move_path?}`. For `add` and `delete` the changed lines
are the content's lines; for `update` they are the diff's `+` and `-` lines,
excluding `+++` and `---`. The `status` is `completed`, `failed` or
`declined` (`protocol.rs:3766-3770`, `:4232-4246`).
`probe2-rollout.jsonl:36` adds one line to `patch.txt` and failed.

### MCP tool calls

`McpToolCall` fields are camelCase. Its title is `server.tool`, and its
result is the text of `result.content`, or `error.message`.

### Legacy pairing

1. Index `function_call{name, arguments}`, `custom_tool_call{name, input}`
   and `local_shell_call{action.command}` by `call_id`.
2. Attach `function_call_output` and `custom_tool_call_output`
   `{call_id, output: string | [items]}` wherever they appear. The output
   text is the non-empty `input_text` parts joined with `\n`
   (`codex-rs/protocol/src/models.rs:2094-2276`).
3. Titles: the `command` argv for `shell` and `container.exec`, `cmd` for
   `exec_command`, the `*** Add/Update/Delete File:` lines for `apply_patch`,
   and the tool name otherwise.
4. Exit status, in this order:
   - JSON `{output, metadata: {exit_code}}`, as in 0.45
     (`codex-rs/core/src/codex.rs:3189-3203` at `rust-v0.45.0`);
   - `Exit code: N` (`codex-rs/core/src/tools/mod.rs:101-125`);
   - `Process exited with code N`
     (`codex-rs/core/src/tools/context.rs:524-545`);
   - otherwise unknown. Which versions wrote which format is Not verified.
5. `patch_apply_end` (with `changes`), `mcp_tool_call_end` and
   `web_search_end` add results.
6. A call with no output at the end of the file is still running while the
   agent works, and never got a result otherwise.

### Line sizes

The largest line of each kind in the local scan: `custom_tool_call_output`
12.1 MB; a user response item with data-URL images 11.9 MB;
`CommandExecution` 7.0 MB; `function_call_output` 5.7 MB; `compacted`
5.6 MB; `McpToolCall` 1.05 MB; `FileChange` 739 KB; `UserMessage` 485 KB;
`session_meta` 49 KB; `AgentMessage` 36.6 KB.

- In 0.160.1, `CommandExecution` repeats its output up to three times
  (`stdout`, `aggregated_output` and `formatted_output`).
- Upstream main drops `stdout`, `stderr` and `formatted_output`, and
  truncates `aggregated_output` at 64 KiB with
  `"\n... command output truncated for persistence ...\n"`.
- `command`, `cwd`, `parsed_cmd`, `source` and `status` all precede the
  output, so a 16 KiB prefix is enough to title even an oversized line.

## Skills and /compact

### Skill prompts

A skill prompt is typed as `$name args`.

- When the TUI recognizes the name, the user item records
  `[text("$name args"), skill{name, path}]`. Parts are ordered images, text,
  skills, then mentions
  (`codex-rs/tui/src/chatwidget/input_submission.rs:129-470`).
- TUI skill names use `[A-Za-z0-9_-]`
  (`codex-rs/tui/src/mention_codec.rs:273-275`). For a plugin skill
  `plugin:skill`, the TUI stops at `:` and records no skill part. Core still
  selects the skill from the text, since it allows `:`
  (`codex-rs/skills/src/mentions.rs:226-228`,
  `codex-rs/skills/src/selection.rs:42-100`).
- The skill's instructions arrive as a hidden `<skill>` response item.
- A legacy `user_message` keeps only the text.
- Reading one back: text that starts with `$<name>` (`[A-Za-z0-9_:-]+`)
  followed by whitespace or the end is a skill prompt when a `skill` part
  names it or the name is a known skill. Chat then shows it in the `/name`
  form it uses for every agent. Any other text, such as `$HOME x`, is
  unchanged.

### Compaction command

`/compact` in the TUI calls `compact()` and records no user message
(`codex-rs/tui/src/chatwidget/slash_dispatch.rs:294-312`). A paginated
rollout then records:

1. `task_started` (`codex-rs/core/src/compact.rs:141-146`);
2. `compacted`, then an optional `world_state`, an optional `turn_context`
   and `thread_settings_applied`
   (`codex-rs/core/src/session/mod.rs:4104-4214`);
3. `item_completed{ContextCompaction}`
   (`codex-rs/core/src/compact.rs:395-396`);
4. `task_complete` (`codex-rs/core/src/tasks/mod.rs:629`, `:844`).

A legacy rollout records `context_compacted` instead of the item. herdr
receives `SessionStart` with the source `compact` and the same id. The turn
has no user message, so the first `ContextCompaction` after a sent `/compact`
is its only trace. No fixture covers this; the order comes from source only.

## Prompt recording and echo matching

herdr's `agent.prompt` writes the text as a bracketed paste
(`ESC[200~text ESC[201~`) when the program has enabled bracketed paste, then
Enter (herdr `src/app/api_helpers.rs:25-32`, `:48-58`). It refuses with
`empty_agent_prompt`, `agent_blocked` or `agent_not_ready` (herdr
`src/app/api/agents.rs:111-216`). The Codex TUI then:

1. **Pastes**
   (`codex-rs/tui/src/bottom_pane/chat_composer/paste_input.rs:118-156`).
   CRLF and CR become LF. `sanitize_user_text` drops control characters
   other than `\n` and `\t`, and CSI sequences
   (`codex-rs/tui/src/history_cell/messages.rs:25-65`). A paste of more than
   1,000 characters becomes `[Pasted Content N chars]` and is expanded again
   on submit (`codex-rs/tui/src/bottom_pane/chat_composer.rs:447`). A paste
   that is exactly one readable image path (after trimming, unquoting,
   `file://` and splitting into one shell token) becomes `[Image #N] ` plus
   an attachment (`codex-rs/tui/src/clipboard_paste.rs:255-291`).
2. **Submits** (`codex-rs/tui/src/bottom_pane/chat_composer.rs:2999-3123`):
   it expands placeholders, trims the text (on by default, `:566-595`) and
   rejects empty input.
3. **Steers** while a turn runs: the text joins that turn
   (`probe2-rollout.jsonl:78` lands mid-turn). `client_id` is a fresh UUIDv4
   that the sender cannot set, so it cannot identify a sent prompt.

A paginated rollout records an `item_completed` whose `UserMessage` has an
`id`, a `client_id` and `content` ending in `text{text, text_elements}` with
the trimmed text (`probe2-rollout.jsonl:10`), plus its response-item twin.
A legacy rollout records `user_message{message}`.

Matching a sent prompt to its record follows from this (Not verified):

- Compare after the TUI's own changes: CRLF and CR become LF, C0 controls
  other than `\n` and `\t` and C1 controls are removed, and Unicode
  whitespace is trimmed at both ends. A skill sent as `$name` compares in
  that form.
- Only user items recorded after the send count, and answers to async
  questions never do. In a paginated rollout that means ordinals above the
  last one seen at the send, or any line of a newer segment; in a legacy
  rollout, lines past the read position at the send.
- Repeats are common, so matches go first in, first out and one to one,
  never by prefix or similarity.
- An image-only send records an item with a `local_image` part at the same
  normalized path and the text `[Image #1]`.

## Incremental parsing

- **Framing.** Records end at 0x0A only. A read boundary can split a UTF-8
  sequence but never a `\n`, so complete lines decode and the bytes after the
  last `\n` wait for more. A complete line that does not parse (a torn line,
  or a crash fragment that a reopen sealed with `\n`) is skipped, and reading
  continues after it.
- **Huge lines.** Classifying a line needs at most 512 bytes: the top-level
  `type` sits in the first 99 bytes and `item.type` within the first 227.
  Lines that need no JSON decoding (tool outputs, response items, token
  records) hold over 99% of the bytes. `UserMessage` and `AgentMessage`
  lines stay well under 1 MiB (485 KB and 36.6 KB at most in the local
  scan).
- **Tail windows.** The bytes from the last prompt to the end of the file are
  200 KB at p50, 2.7 MB at p90 and 16.6 MB at p99, so a window over the tail
  often starts mid-turn. Paginated items carry `turn_id`, so a partial turn
  still groups correctly; legacy events do not, so the first legacy turn in a
  window is incomplete.
- **Following.** A file shorter than the read position, or whose first line
  or last read bytes changed, was rewritten. A file that disappears may have
  been archived into `archived_sessions/`.

## Not verified

- Legacy behavior, which rests on source only, including which versions
  wrote which exec output format and what a declined question writes.
- Non-empty code-mode `aggregated_output`, `/compact` turns and lone
  image-path pastes: read in source, never observed live.
- Where a revert made on a later day places its file. A search for the
  newest rollout must include today's directory.
- The matching rules in
  [Prompt recording and echo matching](#prompt-recording-and-echo-matching).
