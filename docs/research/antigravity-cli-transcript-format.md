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
canceled); the 13 `schedule` waits that ran in the background got none, so
Chat tracks no task for a wait and shows its call done once agy goes on
past it. The `RUNNING` body tells the model how to follow the task (`YOU
MUST TAKE ONE OF THE FOLLOWING TWO ACTIONS …` on a command), so Chat shows
none of it as output. A `manage_task` call can report the status too. When the turn has already
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

Observed live on agy 1.5.3 through herdr 0.9.5 (2026-11-07 and 08) at
120×40, the phone's 62×41, 62×20 and 40×30, the Heeler app's 59×41 and the
desktop's 190×49. The screen fixtures under
`Tests/HeelerTests/ChatFixtures/screens/agy/` are those reads; the numbers
below are their stems. agy draws inline on the normal screen, so a read also
holds scrollback above the box.

### The box

- Two full-width rules of `─` from column 0 in 256-color 8 (grey). Between
  them, `>` at column 0 in color 12 (bright blue, not bold) and the draft in
  the default color from column 2. A wrapped draft and a typed newline both
  continue at column 2, so the two read the same (15, 16, 59). The box grows
  upward as a draft grows once the screen is full.
- The footer under the bottom rule: `? for shortcuts` when the box is empty,
  `esc to cancel` while a turn runs, `Press up to edit queued messages` while
  a message waits, and nothing at the left with a draft. The mode, model and
  effort sit at the right edge in dim text.
- Accept-edits, auto and plan modes set a grey hint after `> ` in an empty
  box, such as `Plan mode: research & plan only (shift+tab to cycle)`, cut
  with `...` at 40 columns (76, 84). It stays until a key is typed.
- Bash mode: `!` on an empty box turns the marker into a bold blue (color 4)
  `!` and the footer into `activated bash mode · esc to cancel` (91, 93).
- Over the box: the welcome before the first prompt, a bold yellow
  `1 artifact · /artifact to review` row after a plan (79), the spinner row
  while working, and a grey `▸ <text> (alt+m to send immediately)` row for a
  queued message.
- Under the box, in place of the footer and each taking Enter: the `/` and
  `@` popups, the `?` help, the `/model` picker and the artifact review panel
  Ctrl+R opens (19, 25 to 29, 80, 85). A background task adds a panel
  between the box and the footer, `● [hh:mm:ss]  <command>  running` and a
  rule (72).
- Past prompts in the scrollback are bold color 4 `> text` rows under a grey
  rule `min(60, columns − 3)` wide, never the full width, so they never read
  as the box. `/compact` leaves a full-width rule labelled
  `Conversation compacted` above the box.
- After agy exits, its last frame stays above `Resume with -c (or command
  below):`, `agy --conversation=<id>` and the shell's prompt (88).

### Keys

| State | Key | Result |
|---|---|---|
| Working | Esc | The turn stops (`⎿  Interrupted · …`) and the box is left empty; a queued message comes back into the box (38, 97) |
| Working | Ctrl+C | The same, and no exit is armed (39) |
| Idle | Ctrl+C or Ctrl+D | Arms an exit, `press ctrl+c again to exit`, with no timeout; a draft stays (03, 07). A second press exits |
| Exit armed | A typed key, Esc, or a paste through herdr's `agent prompt` | Disarms it; the pasted message is sent (04, live) |
| Idle draft | Esc, Esc within 0.25 s | One Esc does nothing; two clear the draft (05, 06) |
| Bash mode | Esc | Leaves bash mode and drops the text (93) |
| Empty box | `?`, `!`, Up | Help, bash mode, the previous prompt from the global history as a draft (19, 91, 92) |
| Working | Enter | Queues the message, which agy delivers within the turn or at its end (34, 35) |

Shift+Enter, Alt+Enter and Ctrl+J insert a newline. herdr's `agent prompt`
pastes its text, and a pasted message reaches the model as typed: bare
`exit`, `quit` and `:q`, a leading `?` or `:` (help and code search open
only for a key on an empty box), and `/btw` after the start all went to the
model as text (live, 2026-11-08). `/compact ` with a trailing space runs
compaction; only `/exit` and `/quit` quit.

### Dialogs

Each dialog takes the box's place: no `>` row between full-width rules while
it shows. It has a bold yellow title (`Command`, `Pending edit`, `Create
file`, `Question`, or `Accessing workspace:` for the trust prompt) over a
full-width grey rule (none under the trust prompt's title), the request, a
bold question, numbered options with the selected one `> N. …` in color 12,
a hint row, and the footer `esc to cancel`. A long option label continues at
column 0. Scrollback keeps an answered dialog only as a `● Ran …`, `● Edited
…` or `? <question>` row. A declined one keeps its title at column 0, bold
blue (4) instead of yellow (3), over `⎿  User declined the tool call` (56,
69, 83, 88); Heeler frames a dialog by the bottom-most bold yellow title
with a rule under it, so it never reads that title as one.

| Dialog | Question and hint row | Keys | herdr 0.9.5 |
|---|---|---|---|
| Trust, at start (00, 10 to 12) | `Do you trust the contents of this project?`, which wraps at 40 columns; `↑/↓ Navigate · enter Confirm`; two options without numbers | Arrows and Enter | Blocked at 190 and 62 columns, **idle at 40** |
| Command (30, 31, 55, 77, 108) | `Run this command?`; `↑/↓ Navigate · tab Amend · ctrl+g edit/expand command`; `Yes, run command`, two `always allow` rules (this conversation, or saved in settings.json), `No, cancel` | A digit picks and confirms at once; Esc or Ctrl+C stops the whole turn; Tab opens Amend on the selected row | Blocked |
| Command's Amend field (52, 109 to 111) | `    > ` under the row, whose label becomes `Yes, and tell Antigravity CLI what to do next` or `No, and tell Antigravity CLI what to do differently`; `enter Submit` | On Yes, Enter runs the command and sends the text as a prompt after the turn (empty, it just runs); on No, Enter declines (`user denied permission`) and sends the text at once. Esc stops the turn | **done** |
| File edit (47, 48, 82) | The path in bold, `N  -  old` and `N  +  new` rows, `shift+tab to auto-approve file edits`, `Accept this file edit?`; `↑/↓ Navigate · f full diff` | As for a command, without Amend | **done** |
| File creation (99) | The path, `N  +  line` rows, `Allow creation of this file?`; `↑/↓ Navigate · f full diff`; `Yes, allow creation`, `No, deny creation` | As for a file edit | **done** |
| Question (41, 42, 44, 45) | `Question N/M: …`; `↑/↓ Navigate · enter Select · esc Skip`; the answers, then `Write-in...` | A digit answers; on a page of several it turns to the next, and on the last it submits them all. Esc skips one question (`User Skipped`) and the turn goes on | Blocked |
| Multi-select question (100 to 103, 113, 114) | Answers drawn `N. [ ] x`; `↑/↓ Navigate · space Toggle · enter Submit · esc Skip`, with `→ Next` on a page of several | A digit selects its answer and toggles it; Enter submits the checked answers (`A1: apple, plum`) or turns the page | Blocked; **done** at 62 columns on a page of several, whose cut hint row loses `esc Skip` |
| Write-in (104, 105) | `  Your answer:` and a field under the answers; `enter Submit · esc Back` | Its digit opens the field; a paste and Enter submit the text | **done** |

**An Enter in the file edit dialog accepts the edit.** herdr's
`permission_prompt` rule needs `tab amend`, which this dialog's hint row
lacks, so herdr reports it done. An `agent prompt` sent then was swallowed,
never reached the model or `history.jsonl`, and its Enter chose
`1. Yes, accept this change` (47, 49, 50). Chat therefore holds any screen
without the box whatever herdr reports, and reads a dialog from its hint row
or question. It holds a running turn as well, since a dialog can open from
one before herdr's Enter (What Chat sends into, below).

agy writes a call that asks the user as its dialog opens (the
`PLANNER_RESPONSE` step) and its result only after the answer and the tool's
run. It records no approval, and Esc records nothing: a stopped call stays
without a result until the next prompt ends its turn. A skipped question's
result reads `User Skipped`.

### The Blocked card

`AgyDialogParser` reads every dialog above into a native card and anything
else between a bold yellow title and a hint row into the generic card,
without numbers. The command's Amend field and the Write-in field keep the
dialog's fingerprint, so a card's step into them checks against the same
dialog. `AgyDialogPlanner` sends these keys, each sequence sent live through
`agent send-keys` on 2026-11-08 except the trust prompt's, since answering it
writes the folder into agy's settings:

| Card action | Keys |
|---|---|
| A permission's option | Its digit. `No` ends the turn, so the card then focuses the composer |
| Stop on a permission | Esc, which stops the whole turn, from the options or a note field |
| A note with `Yes, run command` or `No, cancel` | Down to the row, each step checked, Tab, a check that the field is open and empty, the paste, a check that it holds the note, Enter |
| A single-select answer | Its digit, then a check for `Question i+1/n` on a page of several |
| A multi-select set | The digit of each answer whose check must change, each checked, then Enter |
| A written answer | `Write-in...`'s digit, the field checked, the paste, checked, Enter |
| Skip on a question | Esc, never while the answer field is open (there Esc is Back). On a form, Esc on the page the card showed, in that page's turn |
| Trust | Arrows to the option, each checked, then Enter; no Stop |

Every plan confirms only by the dialog leaving the screen: herdr reports the
file dialogs and fields idle, and no record shows an approval. A card's
answer that showed no effect waits for its call's result. Several questions
fill in on one card and go page by page (`QuestionForm`); the last page's
key submits them all. The screen stays on `Question 1/n` while the card
turns its pages, and Esc skips the question on screen (106), so a form's
Skip marks the page the card shows and goes out as that page's key.

The card reads an idle agy while the open turn has a call without a result
that asks the user (`run_command`, `ask_question`, and the edit and write
tools), and an idle agy that has reported no session for the trust prompt
alone. The reducer offers every open call to the card whatever herdr
reports, since an idle agy's command row reads `no result` while its Amend
field shows. A command sent to the background has its result and keeps no
card. Claude Code's idle-question rule and Grok Build's release on a call's
start do not apply: agy has neither an idle question tool of its own nor a
start record. The card matches a command or a file by the whole command or
path the screen shows, or by its start where the screen cut it (a command
then ends in `…`; a path is cut at the screen's edge without a mark, as at
40 columns in 99), and a question by its text. It shows what the screen
draws and takes from the call only what the screen cut. For a changed line
cut at the edge that is the call's change, a line diff of its target and
replacement, which draws differently from agy: for step 24 of
`approvals.jsonl` (`cherry` becoming `cherry` and `date`) agy draws `1  -
cherry`, `1  +  cherry`, `2  +  date` (47, 48) and the diff `1     cherry`,
`2  +  date`. Both edits captured (47 and probe-a's `hello notes`) draw the
whole target as removed and the whole replacement as added, numbered from
1 though `cherry` is the file's line 3. No capture shows a changed line
long enough to be cut, or a diff taller than the dialog. A call a
confirmed answer went to matches no later card until the transcript
resolves it: agy writes the result only after the call ran, so with two
calls in one response the second's dialog can show before Chat reads the
first's result.

### What Chat sends into

Chat sends only into an empty box with nothing under it and an idle footer
it knows (`? for shortcuts`, nothing at the left, or an armed exit); a
mode's grey hint is not a draft, and an armed exit does not hold. A draft,
bash mode, a popup or panel under the box, another footer (code search
mode's or a Vim badge from agy's strings, if drawn there), a dialog, an
exited agy and any unreadable screen hold the message. agy's strings hold
no badge for Vim's Normal mode (Open questions).

A running turn holds it too: the footer `esc to cancel` or `Press up to
edit queued messages`, or a braille spinner leading one of the bottom rows,
the two cues herdr's manifest reads as Working (`esc_cancel_footer_working`,
`spinner_working`). agy would queue the message, but a dialog can open from
the turn at any moment, and herdr's Enter, written 300 ms after its paste
whatever shows, would answer one that opened after Chat's read. In the pane
reads of 2026-11-07 (about every 160 ms), a pending row (`○ Running (…)`,
`○ Editing 1 file (…)`) with its spinner sat over an empty box for 1.5 to
2.4 s before four dialogs replaced the box, and three command dialogs
opened one read after a spinner row (`Reading file...` or a thought
summary) with no pending row (67 and 69 show the first kind). Since herdr
reads Working from the same screen, its status can only lag Chat's read,
so Chat does not hold on it. What remains is a turn that starts after
Chat's read and opens a dialog before herdr's Enter: one sent from another
client, or the turn agy starts by itself when a background command ends
(Background tasks, above). No probe caught either race; both follow from
the timings above.

Stop sends one Esc, never Ctrl+C. It reads the screen first and sends
nothing while bash mode holds a command, which Esc would drop (93); what
Esc does to a turn from bash mode was not captured.

Chat's `/` menu offers agy's skills as `/name`, except one named like a
built-in command and one whose frontmatter says
`disable-slash-command: true`, which agy keeps for the model and hides from
its `/` popup and from `/name` (agy's changelog, 1.1.12).

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
- `/rewind` and an `EPHEMERAL_MESSAGE` were not captured.
- Screens not captured: two queued messages, code search mode, Vim mode,
  and the background prompt `press %s again to send command to background`.
  If they show as agy's strings suggest, Chat holds code search mode, Vim's
  Insert and Visual badges and the background prompt as unknown footers,
  and two queued messages as a running turn.
- Vim mode's Normal state. agy 1.5.3's strings carry the badges
  `-- INSERT --`, `-- VISUAL --` and `-- V-LINE --` but none for Normal
  mode. Its changelog (1.1.11) puts the badge in the status line;
  `Editor Mode > Insert First` opens the prompt in Insert mode, where a
  bare Enter submits, and Ctrl+S and Ctrl+Enter submit from Normal mode.
  Inferred from those: without Insert First the prompt opens in Normal
  mode, a box there looks like an idle box, and Chat sends into it. Whether
  herdr's Enter then submits, or leaves the message in the box for Chat's
  re-read to report as not delivered, is not known. Heeler reads no agy
  setting that says Vim mode is on.
- Dialogs not captured: `multi_replace_file_content`'s edit, Tab on an
  `always allow` row, a typed answer on a multi-select question, and Esc on
  the trust prompt. Chat leaves the last three to the terminal: the card
  refuses them. It answers a `multi_replace_file_content` edit like any
  other: agy 1.5.3's strings hold one `Pending edit` title and one `Accept
  this file edit?` question, so the edit most likely asks in that dialog
  (inferred, never captured), and a dialog of any other shape gets the
  generic card. Its call records no change Heeler can draw, so the card
  shows the screen's rows.
- Whether `/compact` takes focus text, and which of a skill and a built-in
  command of the same name runs. Chat sends `/compact` as typed and offers
  no skill named like a built-in.
