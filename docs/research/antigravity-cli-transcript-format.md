# Antigravity CLI transcript observations

Versioned observations:

- Antigravity CLI (`agy`) 1.5.3 (macOS arm64), live on scratch conversations
  against herdr 0.9.5 on 2026-11-07: `herdr agent get`, the data root polled
  every 50 ms (sizes, complete lines and a hash per line), `lsof` of the agy
  process during and between turns, pane reads, and a hook dumper placed in a
  scratch workspace for one launch.
- The same agy outside herdr on the same day, for `/clear` and `/fork`.
- A structure-only census of one Host's `~/.gemini/antigravity-cli`: 28
  conversations with a transcript (13 top-level, 15 subagents), 3,502 lines
  in each of the two transcript files, first steps from 2026-10-13 to
  2026-11-05. agy's logs name 1.4.12, 1.5.0 and 1.5.1 for 9 of them; the rest
  are older. Keys, types, short enum values, tool and argument names, counts
  and sizes, never text.
- herdr 0.9.5's agy hook (`HERDR_INTEGRATION_ID=antigravity_cli`, version 4,
  registered under `PreInvocation`) and its `agy.toml` detection manifest
  (2026.10.05.1).
- Issue #644, written against agy 1.5.0. Where it and the above disagree, the
  observations win; each claim is marked below.

The fixtures under `Tests/HeelerTests/ChatFixtures/agy/` come from the live
scratch conversations; their README rows say which steps.

## Identity and location

herdr reports `{source: "herdr:antigravity_cli", agent: "agy", kind: "id",
value}`. It never reported `kind: "path"`, although agy's hook payload
carries `transcriptPath` (pointing at `transcript_full.jsonl`) beside
`conversationId`: herdr 0.9.5 keeps one value per session, and keeps the id.
The value is a lowercase UUIDv4. All 39 conversation folders and 67 database
and lock names in the census have that form. Heeler accepts only a UUID and
lowercases it before it names a path.

When herdr has the id:

- A fresh launch has none until the first prompt. herdr had it within one
  0.1 s poll of the prompt, and the prompt's `USER_INPUT` was already on disk.
- A launch with `--conversation <id>` or `-c` has none until the next
  prompt, though agy holds that conversation's presence lock from launch.
- After `/clear` herdr keeps the old id until the next prompt, while agy has
  already created and locked the new conversation. `/fork` behaves the same.
- After `/exit` the pane's agent and session go.

Files, under the data root `~/.gemini/antigravity-cli`:

| Path | What it holds |
|---|---|
| `brain/<id>/.system_generated/logs/transcript_full.jsonl` | One line per step, tool arguments as JSON values, nothing cut. Chat follows this file |
| `brain/<id>/.system_generated/logs/transcript.jsonl` | The same lines and step indexes, but arguments encoded as JSON strings and long fields cut (below) |
| `brain/<id>/.system_generated/logs/chunks/{transcript,transcript_full}/NNNNNNNN.jsonl` | 100 KiB pieces whose concatenation equals the file; a line can span two |
| `brain/<id>/.system_generated/steps/<N>/output.txt` | A tool result's body; for a background command, its final output |
| `brain/<id>/.system_generated/tasks/task-<N>.log` | A background task's live output |
| `brain/<id>/.system_generated/messages/` | The notifications that become `SYSTEM_MESSAGE` steps |
| `conversations/<id>.db` | agy's own SQLite store (WAL), where replies stream |
| `presence/<id>.lock` | An `flock` agy holds while the conversation is open. The file stays after exit |
| `history.jsonl` | One line per submitted prompt or local slash command |

agy's background updater runs with `--app_data_dir=antigravity-cli
--gemini_dir=.gemini`, and the agy process carried no `GEMINI_*`,
`ANTIGRAVITY_*`, `JETSKI_*` or `AGY_*` variable. Heeler reads the default
root, then each Account directory (one holding a `brain` folder).

The conversation does not exist before its first prompt: no folder, lock or
database. Within one 50 ms poll of that prompt, agy made the folder, both
transcripts, the database, the lock and the history line. `/clear` instead
makes the new folder (without `.system_generated`) and lock at once and the
transcript only with the next prompt, which explains the census's 6 folders
without one. So a folder without its file is a conversation still to start,
and no folder is one the Host does not have.

Both transcripts are append-only: 180 change events in the live run, none
rewriting a byte or leaving a partial line. agy opens, appends and closes for
each write; neither file was open in any of 70 `lsof` samples.

`transcript.jsonl` cuts a string field over about 4 KB to its first and last
2 KB around `\n<truncated N bytes>\n`, and an encoded argument over about
2 KB to its first 2 KB and the marker, which leaves it invalid JSON; the line
lists the fields in `truncated_fields`. `transcript_full.jsonl` never did.
agy's own compaction summary tells the model to read the compact file and
fall back to the full one. The full file was 0.99 to 4.37 times the compact
one (median 1.91); its longest line was 69,703 bytes, one line passed
64 KiB and none 256 KiB.

A forked conversation's file does not copy its parent: the one observed
starts at `step_index` 2. Subagents have folders and transcripts of their
own that start with a `SYSTEM_MESSAGE`; they have no `USER_INPUT`, presence
lock or history line, and herdr reports only the top-level conversation.

`history.jsonl` is not a send witness: the first prompt after a fresh launch
has no `conversationId` (7 ordinary prompts in the census lack it), and a
prompt queued while agy works is logged when it is submitted, not when agy
takes it.

## Records and turns

Every line starts with `step_index`, `source`, `type`, `status` and
`created_at`, in that order; type-specific keys follow. `created_at` is UTC
to the second and is when the step was created, not written: a
`PLANNER_RESPONSE` carries its turn's start (step 3 was created at
15:53:32Z and written at 15:53:47.5Z). A tool result's `content` starts with
`Created At:` and, unless it is still running, `Completed At:` lines in local
time with an offset. No line says when a turn ended.

Census counts by kind:

| Lines | source | type | status | Notes |
|---:|---|---|---|---|
| 1,840 | `MODEL` | `GENERIC` | `DONE` | A tool result; `media` on 67 |
| 1,400 | `MODEL` | `PLANNER_RESPONSE` | `DONE` | `thinking`, `content` and `tool_calls` in any mix; never an empty string |
| 78 | `SYSTEM` | `SYSTEM_MESSAGE` | `DONE` | A task's end, a restart notice, or a message from another conversation |
| 70 | `USER_EXPLICIT` | `USER_INPUT` | `DONE` | A prompt |
| 57 | `MODEL` | `GENERIC` | `RUNNING` | A command or wait sent to the background |
| 26 | `SYSTEM_SDK` | `SYSTEM_MESSAGE` | `DONE` | `This is a periodic system reminder.`, subagents only |
| 20 | `MODEL` | `GENERIC` | `ERROR` | A failed or declined call, with `error` |
| 10 | `SYSTEM` | `CHECKPOINT` | `DONE` | A compaction |
| 1 | `SYSTEM` | `ERROR_MESSAGE` | `DONE` | `content` is `Error: ` and `error` |

Each step is written once, when it settles. A reply is not streamed into
the file: a 20-item list was on screen 7 s before its one
`PLANNER_RESPONSE` line landed. A planner response whose call waits for the
user (a command, a file write or edit, a question) is written as the dialog
opens and its result after the answer; one whose call runs at once is
written with its result. The census has no duplicate or decreasing
`step_index` and, forks aside, every file starts at 0.

**Prompts.** `content` is `<USER_REQUEST>\n…\n</USER_REQUEST>`, then
`<ADDITIONAL_METADATA>` with the local time, and on a conversation's first
message a `<USER_SETTINGS_CHANGE>` block naming the model. Newlines in a
prompt stay; trailing whitespace does not (whether herdr or agy trims it was
not isolated). Plan mode puts `/plan ` before every prompt, inside the
request too. An approved plan comes back as the prompt
`[Approved] implementation_plan.md`.

**Calls and results.** `tool_calls` elements are `{name, args}` with no call
id. Results pair by position: a planner response at step N with K calls is
followed by K results at N+1 to N+K, the kth for the kth call. All 1,917
census results sat where that rule puts them, across 305 batches of more
than one call (up to 14); `view_file`'s `File Path:` header named its own
call's path in all 722 cases. System messages and checkpoints came only after
a whole batch. Tool names differ by version and role (`view_file`,
`replace_file_content` and `write_to_file` beside `read_file`, `edit_file`
and `write_file`), so a name Heeler does not know still gets a row. Result
bodies Heeler reads:

- `run_command`: `Command exited with code N.` then `Command output:` (or
  `No output from the command.`); terminal line ends stay `\r\n`.
- `edit_file`: `Made N replacement in <path> starting at line L (+a/-b
  lines).`, no diff.
- `write_file`: `Created file.`; `write_to_file`:
  `Created file <file URI> with requested content.`
- `ask_question`: `args.questions` is `[{question, options,
  is_multi_select}]`, a recommended option starts `(Recommended) `, and the
  result is one `A<n>: <answer>` line per question, `User Skipped` for one
  left unanswered.
- An `ERROR` result is `Encountered error in step execution: <error>`, the
  `error` field verbatim. A declined permission reads
  `permission check failed for …: user denied permission …`.

**Ending a turn.** Nothing marks a turn's end: the turn ends with its last
planner response, and the next `USER_INPUT` starts another.

- Esc or Ctrl+C while a call runs, or on its permission dialog, writes
  nothing. The interrupted step's number is used up, so the next prompt
  skips one (23 to 25, 26 to 28). Stopping streamed text skipped none: three
  prompts followed each other at steps 11 to 13. Either way, the only trace
  is a prompt after a turn without a reply.
- Declining a call writes its `ERROR` result and ends the turn (the screen
  shows `User declined the tool call`, then the Interrupted line).
- A prompt sent while agy works is queued and written when agy takes it,
  as an ordinary `USER_INPUT`. Esc while one is queued interrupts the turn
  and puts the text back in the input box, unsent.

**Background tasks.** A `run_command` that outlives its `WaitMsBeforeAsync`
writes one `GENERIC` with status `RUNNING` and `Tool is running as a
background task with task id: <conversation>/task-<N>`, N being its own step.
That line is never followed by a `DONE` for the step. The end comes as a
`SYSTEM_MESSAGE` from `<conversation>/task-<N>`: `Task id "…/task-N"
finished with result:` or `was canceled with result:`, then the result.
All 44 census commands sent to the background got one (41 finished, 3
canceled); the 13 `schedule` waits that ran in the background got none. A
`manage_task` call can report the status too. When the turn has already
ended, agy starts one on its own: the system message, then a planner
response, with no `USER_INPUT` and no history line.

**System messages.** `content` opens with a preamble that names the tag
(`The following is a <SYSTEM_MESSAGE> not actually sent by the user. …`),
then a blank line and the real `<SYSTEM_MESSAGE>` block, whose one line is
`[Message] timestamp=… sender=… priority=… content=<text>`. Resuming a
conversation (`--conversation`, `-c`) appends after the next prompt a
low-priority `[Notice] All your subagents and background tasks have been
stopped due to server restart. …`, whether or not anything was running.

**Compaction.** `/compact` reaches the model as an ordinary prompt; no
`type` marks it in history. Its result is one `CHECKPOINT`, whose content
holds `# Resuming from a compaction`, a `<summary>` with numbered bold
sections such as `**Task Overview**`, and `# Conversation Logs`. No planner
response follows. The census's 10 checkpoints all fell between a result and
a planner response, compactions agy made inside a turn.

**Errors.** The one census `ERROR_MESSAGE` (`The stream was interrupted.
Please continue the task you were working on.`) was followed by a planner
response, so the turn went on.

Issue #644's claims against these observations:

| Claim | Finding |
|---|---|
| Every line has `created_at`, `source`, `status`, `step_index`, `type`; four sources; three statuses | Confirmed (3,502 of 3,502); `RUNNING` and `ERROR` occur only on `GENERIC` |
| The hook forwards `agent_session_path` when `transcriptPath` is present | agy sends `transcriptPath` (the full file); herdr 0.9.5 reports only the id |
| `tool_calls[].args` values are JSON-encoded strings | Only in `transcript.jsonl`; the full file has JSON values |
| A background command writes two `RUNNING` lines with one `step_index` | Refuted: one line, never updated (0 duplicates) |
| A `RUNNING` result updates the pending call, and a later line completes it | Refuted: the end is a later task notification |
| An interrupted call leaves the next prompt at N+2 | Confirmed for Esc and Ctrl+C during a call; not for stopped text |
| `ERROR_MESSAGE` ends the turn as failed | Refuted: the census's one was followed by more work |
| `truncated_fields` is only `["content"]` | Refuted: also `tool_calls` and `thinking`, and only in `transcript.jsonl` |
| `EPHEMERAL_MESSAGE` from `SYSTEM_SDK` | Not seen: `SYSTEM_SDK` wrote only reminders as `SYSTEM_MESSAGE` |
| `USER_INPUT` may carry `media` | Not seen; `media` appeared only on results (`read_file` and `view_file` images) |
| Every prompt adds a history line with `conversationId` | Refuted for a fresh launch's first prompt; queued prompts are logged at submit |
| The presence lock is held for the process's life | Only once a conversation exists; lock files outlive their process |

## Screen, input and keys

## Open questions

- When a turn ended. `created_at` is a step's start, so the last step's
  time is not the end; Chat records no end time for agy turns.
- The working directory. No line records it, so relative paths cannot be
  resolved and Chat shows the absolute paths agy records.
- Plan artifacts. The `/plan` turn wrote `implementation_plan.md` with
  `write_file` and an `ArtifactMetadata` argument; Chat shows it as a file
  write, not as a plan.
- A line cut at Heeler's line cap. The step's index, type and status survive,
  but an unfinished string is dropped whole, so its text is lost.
- An environment variable that moves the data root. None was found, and
  Heeler reads only the default root and Accounts.
- A queued message delivered inside a running turn. One was seen arriving as
  a new prompt while a background command ran, rather than at the turn's end;
  where its turn should start is not settled.
- `/rewind`, multi-select and write-in answers, and an `EPHEMERAL_MESSAGE`
  were not captured.
