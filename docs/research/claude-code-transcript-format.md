# Claude Code transcript format

Observed on 2026-10-06. Claude Code 2.1.291 wrote the probe transcripts, and
its CLI bundle and the matching Agent SDK are the cited sources. The spill
directory for long tool output was also seen with the installed 2.1.292 CLI.
herdr was 0.9.3 (protocol 22).

This note records the on-disk transcript format that native Chat reads: which
records exist, which of them form the conversation as it now stands, and what
a reader can rely on while the CLI is still writing.

## Evidence and provenance

Citations such as `probe2-transcript.jsonl:5` name a file in
`Tests/HeelerTests/ChatFixtures/claude/` and a 1-based line; a following `:86`
is another line of the same file. Screen citations such as
`screens/claude/claude-21-c6-after.ansi` are relative to
`Tests/HeelerTests/ChatFixtures/`. The probes ran against an isolated herdr
backend. Scrubbing kept every byte offset and line number (see the fixtures
README), but the probe tooling re-serialized each line, so the fixtures are
not byte-identical to the compact JSON Claude Code writes.

| Source | Version | Cited as |
| --- | --- | --- |
| Probe transcript | Claude Code 2.1.291, 166 lines | `probe2-transcript.jsonl` |
| Probe subagent | Claude Code 2.1.291, 19 lines | `probe2-subagent.jsonl` and `probe2-subagent.meta.json` |
| Probe screens | herdr 0.9.3 visible-screen reads | `screens/claude/<name>.ansi` |
| CLI | Claude Code 2.1.291 native build | a module of its embedded bundle and a minified identifier in it, for example `chunk-v1gtm86q.js` `uh` |
| Agent SDK | `@anthropic-ai/claude-agent-sdk` 0.3.291 (`claudeCodeVersion` 2.1.291) | a minified identifier in `sdk.mjs`, for example SDK `Eu`, or `sdk-tools.d.ts:<line>` |
| Python SDK | `claude-agent-sdk-python` at `1cc862c4`, which bundles CLI 2.1.291 | `src/claude_agent_sdk/_internal/sessions.py:<line>` |
| herdr | v0.9.3 (`7b116c05`) | herdr `src/<path>:<line>` |
| Local scan | transcripts on one development machine, 2026-10-06 | aggregate counts only |

Minified identifiers mean something only within that build, and one name can
occur in several modules, so CLI citations give the module. CLI line numbers
are omitted because they depend on how the bundle is formatted.

Statements without a label were checked against a fixture line or the cited
source. **Not verified** marks statements reasoned from source or
documentation but not observed; [Not verified](#not-verified) collects them.

## Record types

Each line is one JSON object with a `type`. Chain records carry `uuid` and
`parentUuid`: `user`, `assistant`, `system`, `attachment` and `progress` (SDK
`Lve`). Every other type is a metadata line without a `uuid`.
`probe2-transcript.jsonl` holds 119 chain records and 47 metadata lines.

| Envelope field | Meaning |
| --- | --- |
| `uuid`, `parentUuid` | The tree edge. `parentUuid` is null at the root (`probe2-transcript.jsonl:5`) and on `compact_boundary`. |
| `logicalParentUuid` | Only on `compact_boundary`: the last message before the compaction (CLI `chunk-v1gtm86q.js`). |
| `isSidechain` | True on every record of a subagent file (`probe2-subagent.jsonl`). Sidechain records never join the main conversation. |
| `isMeta` | Model-only input, such as skill bodies, caveats and reminders. |
| `sessionId` | The file's session id. In a subagent file it is the parent session's id (`probe2-subagent.jsonl:1`). A `session_id` field, where present, differs from it in 9,834 user records of the local scan and is not an identity. |
| `agentId`, `teamName` | Subagent and team records. |
| `timestamp` | Display only, never an order key. |
| `promptId` | Shared by the user records of one prompt's turn, tool results included. A subagent's root record carries the `promptId` of the turn that started it. |

### User records

- **Prompt.** String content, or `text` and `image` blocks with
  `imagePasteIds`. Also `promptSource` (`typed`, `system`), `origin.kind`
  (`human`, `task-notification`), `turnOrigin`, `turnPosition` and
  `permissionMode` (`probe2-transcript.jsonl:5`).
- **Tool result.** Content
  `[{type: "tool_result", tool_use_id, content, is_error?}]`, where `content`
  is a string or a list of `text`, `image` and `tool_reference` blocks. A
  `text` block after the result holds the note typed with an approval
  (`probe2-transcript.jsonl:40`, `:86`). Top-level fields: `toolUseResult`
  (the tool's JSON, or a string for errors), `sourceToolAssistantUUID`,
  `toolDenialKind` (`user-rejected`, `permission-rule`, `automode-blocked`,
  `automode-unavailable`), `userFeedback` and `toolDenialUnanswered`.
  `is_error` may be absent (`probe2-transcript.jsonl:48`, `:60`).
- **Interrupt marker.** The text `[Request interrupted by user]` or
  `[Request interrupted by user for tool use]`
  (`probe2-transcript.jsonl:109`), with optional `interruptedMessageId` (an
  assistant `message.id`) and `interruptedByShutdown`.
- **Compaction summary.** `isCompactSummary` and `isVisibleInTranscriptOnly`,
  with string content.
- **Tagged text.** See [Special flows](#special-flows).

### Assistant records

Each record holds one content block (`probe2-transcript.jsonl:25`) in
`message{id, model, content: [block], stop_reason, usage}`, with `requestId`,
`apiBlockIndex`, `thinkingDurationMs` (647 at `:106`) and `attribution*`
fields.

- Blocks: `text`; `thinking{thinking, signature}`, whose text is often empty;
  `redacted_thinking`; `tool_use{id, name, input, caller}`;
  `fallback{from.model, to.model}`. Unknown block types should be skipped.
- Error rows carry `isApiErrorMessage`, `model: "<synthetic>"`, `error`
  (`rate_limit`, `server_error`, `authentication_failed`) and
  `apiErrorStatus`.
- Partial rows carry `isAbortedMidStream` or `truncatedAfterOutput`.

### System records

| Subtype | Fields and notes |
| --- | --- |
| `turn_duration` | `durationMs`, `messageCount`, `pendingBackgroundAgentCount?`. It sits on the chain: the next prompt's parent is the `turn_duration` record (`probe2-transcript.jsonl:37` is a child of `:35`). |
| `compact_boundary` | `compactMetadata{trigger, preTokens, preservedSegment{headUuid, anchorUuid, tailUuid}, preservedMessages{anchorUuid, uuids}}` |
| `local_command` | `content`, `level` (CLI `chunk-v1gtm86q.js` `uh`) |
| `away_summary` | `content` |
| `model_refusal_fallback` | `retractedMessageUuids` |
| `informational`, `scheduled_task_fire`, `agents_killed`, `memory_saved` | Status records |
| `api_error` | CLI `pW`. Never seen in a file; Not verified whether it is ever written. |

### Attachment records

Attachments sit on the chain. The probe transcript alone has 16
`attachment.type` values, such as `total_tokens_reminder`,
`deferred_tools_record` and `skill_listing`, and most carry no conversation
content. These do:

- `queued_command{prompt, source_uuid, commandMode, origin, isMeta,
  imagePasteIds}`. With `commandMode: "prompt"` it is a prompt delivered
  mid-turn. The SDK includes it unless a user record with
  `uuid == source_uuid` exists (SDK `fCe`, `LM`), and converts it only once
  it was delivered or followed by a reply (`uCe`, `pCe`). With
  `commandMode: "task-notification"` it is a background task's completion
  (see [Special flows](#special-flows)).
- `plan_mode` (`probe2-transcript.jsonl:61`). Its body is redacted in the
  fixture, so it is Not verified that it carries `planFilePath`.
- `plan_mode_exit{planFilePath, planExists}` (`probe2-transcript.jsonl:87`).

### Progress records

2.1.291 does not write them. A reader can index them, but they carry no
content and are never a leaf.

### Metadata lines

Metadata lines have no `uuid`, and the last value wins. The CLI re-appends a
block of them, so the tail of a file holds the current values.

- **Title.** `custom-title{customTitle}` wins over `ai-title{aiTitle}`, which
  wins over `summary` (`probe2-transcript.jsonl:140` is the `ai-title`
  `create-and-verify-probe-file`). There is also `agent-name`.
- **Permission mode.** `permission-mode{permissionMode}` records are
  snapshots, not a timeline. After the plan approval the TUI showed auto mode
  (`screens/claude/claude-21-c6-after.ansi`), yet the transcript has no `auto`
  record.
- **Last prompt.** `last-prompt{lastPrompt, leafUuid}` does not name the
  current leaf: `probe2-transcript.jsonl:139` names line 138, while the leaf
  is line 165.
- **Others.** `queue-operation{operation, content?}`
  (`probe2-transcript.jsonl:130-131`), `continued-in{continuedInSessionId}`,
  `relocated{relocatedCwd}`, `fork-context-ref`, `file-history-*`,
  `cost-state`, `mode`, `atis-latch`, `pr-link` and `frame-link`. Unknown
  types can be ignored.

## Current branch

A transcript is a tree. Rewinds, parallel tool results and compactions all
leave records that are not part of the conversation as it now stands. The
SDK's session reader picks the current branch (SDK `Eu` relinks compactions
and finds the leaf; `cCe` re-inserts siblings). The steps below follow it,
with one extension so history before a compaction stays reachable:

1. **Index.** Map `uuid` to record; the last occurrence wins, as in the SDK.
   A record's position is the byte offset of its line.
2. **Relink compactions.** For each `compact_boundary` in file order, on a
   copy of the parent pointers: if every `preservedMessages.uuids` entry
   exists, chain them after `anchorUuid` and move the anchor's other children
   to the last of them. Otherwise use `preservedSegment`: the head's parent
   becomes `anchorUuid`, and the anchor's other children move to `tailUuid`.
3. **Leaf.** Eligible records are not `isSidechain`, have no `teamName`, are
   not `progress` and are not a `fork_briefing` attachment. Candidates are
   eligible records with no eligible child, newest first. From each, walk up
   to the first `user` or `assistant` record that an earlier candidate's walk
   has not visited. The first hit is the leaf, and its candidate is the
   terminal. If nothing qualifies, take the newest `user` or `assistant`
   terminal, preferring non-meta records.
4. **Walk** from the terminal, not the leaf, to a null parent, with a cycle
   guard. Starting at the terminal keeps a trailing `turn_duration`,
   `local_command` or queued command on the branch.
5. **Segments** (the extension). The SDK stops where the walk reaches a
   `compact_boundary`. To keep earlier history, mark the boundary and continue
   from the newest unvisited eligible terminal positioned before it, with the
   same walk-up, stopping at visited records. Over 159 transcripts in the
   local scan, this reached 98.0% of non-sidechain user and assistant records
   with no duplicates. Boundary geometry in a capture is Not verified.
6. **Siblings.** Add off-chain `assistant` records that share a `message.id`
   with an on-chain one, and `tool_result` records that answer an on-chain
   `tool_use` (with the same `isSidechain` and `agentId`) that has no on-chain
   answer. The SDK inserts these by timestamp. Sorting the selected records by
   position gives chain order for linear chains and leaves preserved records
   where they were written.
7. Records left out were rewound or abandoned.

On `probe2-transcript.jsonl` the terminals are lines 166, 162 and 85. The leaf
is line 165 with terminal line 166, the walk covers lines 5 to 166 (117
records), and the siblings are line 85 (parent 83) and line 162 (parent 160).
All 119 chain records are selected, and every parent precedes its child.

How branches form:

- **Parallel tools and streaming execution**
  (`probe2-transcript.jsonl:83-86`, `:160-163`). A result that arrives before
  the next block is written hangs off the block it answers and dead-ends;
  step 6 recovers it.
- **Rewind or edit** (`Esc Esc`, `/rewind`). The next prompt becomes a
  sibling under the restored parent, and the old branch stays in the file.
  Not verified.
- **Retries and fallback.** A retried request under the same parent gets a
  new `message.id`, and blocks marked `isAbortedMidStream` may dead-end. Not
  verified. The `retractedMessageUuids` of `model_refusal_fallback` were
  already gone from the files where they were seen.
- **Sidechains** never enter the main chain.
- **Two writers.** A session resumed in two places interleaves both writers
  in one file, so the leaf may flip; the newest wins.

## One API message across records

Each content block of one API response is its own `assistant` record. The
records share `message.id` and `requestId` and number their blocks with
`apiBlockIndex` from 0 (`probe2-transcript.jsonl:74-77`, `:83-86`,
`:106-107`, `:160-161`). Block k's parent is block k-1, or the `tool_result`
for block k-1 when that tool finished first (`probe2-transcript.jsonl:76` is a
child of `:75`). `stop_reason` and `usage` repeat on every record and are
unreliable, often null in subagent files.

Reading them back:

- Group by `message.id` (by `uuid` for `<synthetic>` error rows) and order by
  `apiBlockIndex`, then by position.
- Keep one item per block rather than concatenating them. Whitespace-only text
  blocks carry nothing.
- For a duplicate `(message.id, apiBlockIndex)`, prefer the record on the
  current branch, else the newest.

## Tool pairing and outcomes

A result pairs with its call by `tool_use_id` within the selected records. In
the local scan the `tool_use` always preceded its result (108,334 of 108,334
pairs), and metadata lines may sit between the two
(`probe2-transcript.jsonl:138` and `:145`).

How a call that has a result ended; the first matching row wins:

| Evidence | Outcome | Fixture |
| --- | --- | --- |
| `toolDenialKind`, or an error starting `The user doesn't want to proceed with this tool use.` (CLI `chunk-v1gtm86q.js` `lC`, `R0`) | Declined. The feedback is `userFeedback`, else the text after `the user said:\n`. | `probe2-transcript.jsonl:26`, `:81` (feedback); `:108`, `:119` (none) |
| An error starting `Permission for this tool use was denied` (`lB`, `JQ`) | Declined by a rule or a subagent | none |
| Text starting with a marker from the CLI's interrupt list (`chunk-p4rztmns.js` `the`; SDK `LI`) | Interrupted or not completed | none |
| `toolDenialUnanswered` | Not completed: the approval request expired | none |
| Any other `is_error: true` | Failed | none |
| Anything else | Succeeded. A `text` block after the result is the note typed with the approval. | `probe2-transcript.jsonl:40`, `:86` |

A call without a result is still running, or waiting for approval, while its
turn is open. Once a later prompt or `turn_duration` exists, it never got one.

A decline without feedback ends the turn and is followed by
`[Request interrupted by user for tool use]`
(`probe2-transcript.jsonl:108-109`, `:119-120`). A decline with feedback lets
the turn continue (`probe2-transcript.jsonl:34`). No record marks an
approval: a manual approval looks the same as an automatic allow.

### Result fields by tool

| Tool | `input` | `toolUseResult` |
| --- | --- | --- |
| Bash | `description`, `command` | `stdout`, `stderr`, `interrupted`, `backgroundTaskId`, `persistedOutputPath`, `persistedOutputSize` (`sdk-tools.d.ts:3267`); `bashEditDiff` when recorded ([below](#files-a-bash-command-changed)) |
| Edit | `file_path` | `structuredPatch[{oldStart, oldLines, newStart, newLines, lines}]`; changed lines start with `+` or `-` (`sdk-tools.d.ts:3400`) |
| Write | `file_path` | `type` `create` with `content` (`probe2-transcript.jsonl:75` adds 2 lines, `:93` adds 1), or `update` with `structuredPatch` (`:85` adds 2 and removes 2) (`sdk-tools.d.ts:3452`) |
| Read | `file_path` | `type: "text"` with `file{numLines, startLine, totalLines}`; images, PDFs and notebooks have other shapes (`sdk-tools.d.ts:208`) |
| Agent (older name `Task`) | `description`, `subagent_type` | `status` `completed` with `totalToolUseCount` and `totalDurationMs`, or `async_launched` with `agentId` (`sdk-tools.d.ts:102`; `probe2-transcript.jsonl:126`) |
| AskUserQuestion | `questions[]` | `answers` maps each question to its answers joined by `, `: `probe2-transcript.jsonl:48` has `Red, Blue` and the typed answer `Medium` |
| ExitPlanMode | `plan`, `planFilePath` | `plan` is the approved plan. `input.plan` can be stale: `probe2-transcript.jsonl:84` proposes p.txt while `:86` holds q.txt |
| EnterPlanMode | none | `message` (`probe2-transcript.jsonl:60`) |
| Glob and Grep, WebFetch, TodoWrite | `pattern`, `url` | `numFiles`; `code` and `bytes`; `newTodos` |
| ToolSearch | `query` | Result content `[{type: "tool_reference"}]` (`probe2-transcript.jsonl:56`) |
| Other tools and MCP | `name` | The result's first text |

Bash output too large to inline is spilled to a file. `persistedOutputPath`
names it, in the session's `tool-results` directory
`<projectDir>/<sessionId>/tool-results/`, which is the transcript path
without `.jsonl` followed by `/tool-results/` (CLI `chunk-1g0h7ksr.js` `Ft`;
also seen with the installed 2.1.292 CLI). `persistedOutputSize` is the full
output's size in bytes (`sdk-tools.d.ts:3324-3331`).

### Files a Bash command changed

Observed on 2026-10-07 in the installed 2.1.292 CLI and in Bash results of
this repository's own sessions; the probe transcripts do not record it, and
2.1.282 already did. The result's `bashEditDiff`:

- **Shape.** `{files: [{filePath, hunks, created?, deleted?}], moreFiles,
  changedFiles?, unavailable?, skipped?, shared?}`. `filePath` is absolute.
  `hunks` has Edit's `structuredPatch` schema, but lines keep literal tabs,
  where Edit and Write turn leading tabs into two spaces. `changedFiles` names
  at most 200 absolute paths.
- **Gate.** The `CLAUDE_CODE_BASH_EDIT_DIFF` environment variable, else the
  `bashEditDiffEnabled` setting, which only user, flag and policy settings can
  turn on, else on in auto and bypassPermissions modes while the "bash-first"
  prompt gate is on. That gate also steers the model to edit files through
  Bash, so these sessions show few Edit calls.
- **Coverage.** Only the git repository the command runs in, tracked and
  untracked files that are not ignored. macOS compares snapshots of the
  working tree; Linux watches files and writes jsdiff hunks, with
  `\ No newline at end of file` lines and other zero-length hunk starts.
  Nothing is recorded for background, interrupted, failed or read-only
  commands, outside a repository, or for the Windows PowerShell tool. A
  subagent's commands record in its own transcript.
- **Caps.** At most five files carry hunks. A file whose diff reaches
  400 lines or 64,000 characters is only named, and `moreFiles` counts the
  changed files `files` leaves out. `shared` means another recording command
  ran in the same repository at the same time; `unavailable` and `skipped`
  mean the diff was not taken.
- **Terminal.** Renderer `B` (beside `te=40`) shows one note when `skipped`,
  or when `unavailable` or `shared` comes without files. Otherwise each file
  shows `Created`, `Deleted` or `Updated`, its path relative to the working
  directory and `(+a -b)` counted from its hunk lines, then at most 40 hunk
  lines (`oe`, which counts marker lines too) and `… N more lines`. Then come
  `… N more files changed` (with no files,
  `N files changed (binary, mode only or too large to show)`), with
  ` (part of the diff is unavailable)` when `unavailable`; a git-step note;
  and the shared note. The git-step note shows when `XKr`
  (`chunk-pwkr374y.js`) finds a simple command whose words, after one leading
  `sudo`, are `git` and a first non-option word in `NEn`: `checkout`,
  `switch`, `stash`, `pull`, `merge`, `rebase`, `reset`, `restore`, `clean`,
  `cherry-pick` or `revert`. Only `-C` and `-c` take the next word. It
  reads the simple commands of the permission analysis (`MG`,
  `chunk-acz3memr.js`), which include those inside `$(…)` in double quotes;
  when that analysis isn't simple, or the command is over 10,000 characters
  (`DM`), it reads only the top-level statements (`jd`, `Pu`). While that
  note shows, the hunks stay hidden until the view is expanded.

## Subagents

- **Files.** `<projectDir>/<sessionId>/subagents/agent-<agentId>.jsonl`, with
  `agent-<agentId>.meta.json` beside it (`sessions.py:1199-1243`,
  `:1415-1479`). Workflow agents nest under `subagents/workflows/<runId>/`,
  and the CLI names runs `wf_<id>` (`chunk-dvdad336.js`).
- **Linkage**, as captured:
  - The `Agent` call is `probe2-transcript.jsonl:125`. Its result at `:126`
    is `async_launched` with `toolUseResult.agentId`.
  - The meta file's `toolUseId` equals that call's `tool_use` id, and a
    `parentAgentId` marks a nested agent (`sessions.py:1415-1479`).
  - The subagent's root record (`probe2-subagent.jsonl:1`) carries the same
    `promptId` as `probe2-transcript.jsonl:126`.
  - The completion notice carries `<task-id>`, which is the agent id, and
    `<tool-use-id>` (`probe2-transcript.jsonl:132`).
- **Shape.** Every record in `probe2-subagent.jsonl` is `isSidechain` and
  carries the parent's `sessionId`, and its `user` and `assistant` records
  also carry `agentId`. The root user record holds the prompt, and the 19
  records form one linear chain. The rules in
  [Current branch](#current-branch) apply with sidechain records eligible.
- **Permissions.** A call that waits for permission inside a background
  subagent appears only in the subagent's file
  (`probe2-subagent.jsonl:12`), while the pane shows the prompt
  (`screens/claude/claude-26-c10-subagent-ask.ansi`).
- **Paths from content.** `agentId` and run ids come from transcript content.
  Validate them, for example against `^[A-Za-z0-9_-]{1,64}$`, before building
  a path.

## Special flows

The CLI writes these as tagged text or as dedicated records. A tag counts
only at position 0 of the trimmed text; a prompt that mentions
`<command-name>` later is an ordinary prompt.

| Flow | Records | Meaning |
| --- | --- | --- |
| Skill or prompt command `/name args` | A user record `<command-message>name</command-message>\n<command-name>/name</command-name>\n<command-args>args</command-args>`, without the args line when there are none (CLI `chunk-y68pt6m4.js` `et`); then an `isMeta` user record holding the body; then attachments | The prompt is `/name args`; the body is model input |
| Model-invoked skill | `<command-name>name</command-name>` without `/`, plus `<skill-format>true</skill-format>` (`hIo`) | The model ran a skill. Not verified. |
| Local command | 2.1.291: a `system` `local_command` record with `<command-name>/cmd</command-name>`, `<command-message>` and `<command-args>` (12-space indents; `chunk-v1gtm86q.js` `QQ`), then one holding `<local-command-stdout>`. Older CLIs: an `isMeta` caveat, a command user record and a stdout user record | One command and its output. Not verified in a capture. |
| `!` shell command | `<bash-input>`, then `<bash-stdout>` and `<bash-stderr>` | Not verified for 2.1.291 |
| Compaction | `compact_boundary`, then attachments, then an `isCompactSummary` user record | Manual or automatic (`compactMetadata.trigger`); the summary is model context. Not verified in a capture. |
| Plan mode | The EnterPlanMode result, a `plan_mode` attachment and `permission-mode: plan` (`probe2-transcript.jsonl:59-65`); ExitPlanMode with `input{plan, planFilePath}`; a decline with feedback (`:81`); an approval `User has approved your plan…## Approved Plan:` with the note, then `plan_mode_exit` (`:86-87`) | The approved plan is `toolUseResult.plan` or the plan file |
| AskUserQuestion | Results `The user answered: …`, `Your questions have been answered: …` or `The user did not answer the questions.`; Esc gives the `lC` decline | The answers, per question |
| Background task done | A user `<task-notification>` with `task-id`, `tool-use-id`, `output-file`, `status`, `summary`, `note`, `result` and `usage`, `promptSource: "system"` and `origin.kind: "task-notification"`, after a `queue-operation` (`probe2-transcript.jsonl:130-132`) | Finishes the Agent call it names |
| Interrupt | A marker record (SDK `MI`: the text starts with a marker, or every block is text or an error result starting with one) | The turn was stopped |
| API error | `isApiErrorMessage` | An error notice |
| Reasoning | A `thinking` block and `thinkingDurationMs` (`probe2-transcript.jsonl:106`) | The text may be empty |
| Images | `image` blocks in user records or tool results | Base64 data |
| Model switch or retraction | A `fallback` block; `system` `model_refusal_fallback` | `retractedMessageUuids` name records that no longer count |
| `turn_duration`, `away_summary`, `informational` | `system` records | Status, not conversation |
| `isMeta` with `origin.kind` `channel`, `observer`, `observer-activity`, `slack-ping` or `peer` | | The SDK keeps these (`$C`) |
| `<system-reminder>`, other `isMeta`, caveats, hook tags | | Model input only |

## Prompt recording and echo matching

How the 2.1.291 CLI turns a submitted prompt into a record
(`chunk-scapxbwa.js`, `chunk-9jn7d7yq.js`):

1. Invisible characters (tag characters, bidi controls, zero-width characters
   and variation selectors; flag `tengu_tranquil_cloud`, on by default) are
   stripped, and any removal aborts the submit, leaving the stripped text in
   the input box. A sender has to strip them itself.
2. The text is trimmed at the end (`trimEnd()`). An input that is exactly
   `exit`, `quit`, `:q`, `:q!`, `:wq` or `:wq!` runs `/exit`
   (`chunk-v1gtm86q.js` `xPe`).
3. `[Pasted text #N +M lines]` references expand inline. `[Image #N]` stays
   literal, and the images become `image` blocks after the text. Flag
   `tengu_virtual_pancake` (off by default) wraps pastes in
   `<pasted_content id="abcd">…</pasted_content id="abcd">`.
4. While the agent is busy, the prompt is queued after `trim()`: a
   `queue-operation` enqueue, later a user record or a `queued_command`
   attachment.
5. `UserPromptSubmit` hooks may rewrite the prompt or append to it.

herdr's `agent.prompt` writes the text as a bracketed paste when the program
has enabled bracketed paste, then Enter (herdr
`src/app/api_helpers.rs:25-32`, `:48-58`).

What follows for matching a sent prompt to its record:

- Comparing NFC text with LF line ends, `<pasted_content>` unwrapped and both
  ends trimmed absorbs every change above except a hook's.
- Candidates are user records with `promptSource` `typed` (or none) and
  `origin.kind` `human` that are neither meta nor tool results,
  `queued_command` attachments with `commandMode: "prompt"`, and the
  `content` of `queue-operation` enqueues. A task notification is a user
  record too (`probe2-transcript.jsonl:132`) but never an echo.
- The same prompt can be sent twice, so repeats match first in, first out. A
  hook that appends makes the record contain the sent text rather than equal
  it. A skill command records its name and arguments in tags (see
  [Special flows](#special-flows)). `/compact` records no prompt; a later
  `compact_boundary` with `trigger: "manual"` stands for it (Not verified).
  Images are recorded as blocks, so only the text compares.
- Forks and `/clear` start a new session id and file, so a prompt without an
  echo may have landed in another transcript (Not verified for `/clear`; see
  [Location](#location)).

## Location

- **Root.** `<home>/.claude`. An agent started with `CLAUDE_CONFIG_DIR`
  writes elsewhere, and nothing herdr reports reveals that (Not verified).
- **Project key** (CLI `chunk-rc27drnh.js` `eI`). Every UTF-16 code unit
  outside `[A-Za-z0-9]` becomes `-`. A key longer than 200 units becomes its
  first 200 units, `-`, and the base-36 absolute value of
  `h = (h << 5) - h + unit`, computed in wrapping Int32 arithmetic over the
  path's UTF-16 units (|Int32.min| is 2147483648). Whether the path is
  NFC-normalized first is Not verified.

| Working directory | Key |
| --- | --- |
| `/home/dev/project` | `-home-dev-project` |
| `/Users/dev/My Project.v2` | `-Users-dev-My-Project-v2` |
| `/home/dev/café` (NFC) | `-home-dev-caf-` |
| `/home/dev/café` (NFD) | `-home-dev-cafe-` |
| `/home/dev/😀` | `-home-dev---` |
| `C:\Users\dev\proj` | `C--Users-dev-proj` |
| `/home/dev/` and 250 × `a` | The first 200 units, then `-u4xdh7` (Not verified) |
| `/home/dev/`, 100 × 😀 and 10 × `b` | The first 200 units, then `-asy115` (Not verified; the Python SDK hashes code points, so it differs) |

- **Session id.** herdr reports a Claude agent's session as `agent_session`
  with kind `id` and the session UUID as its value. herdr's Claude hook runs
  on `SessionStart`, skips subagents and sends both the session id and the
  transcript path (herdr
  `src/integration/assets/claude/herdr-agent-state.sh:53-82`), but herdr
  keeps a path only for `pi` and `omp` (herdr `src/agent_resume.rs:116-133`),
  so clients receive the id alone.
- **Finding the file.** For each candidate working directory (the pane's
  `cwd` and `foreground_cwd`), look for `projects/<key>/<id>.jsonl`. For a
  long key, list `projects/` and try directories that start with its first
  200 units and `-`, since implementations hash differently. As a last
  resort, try every project directory.
- **Accepting a file.** It is not empty, the first string `sessionId` within
  its first 64 KiB equals the id (`probe2-transcript.jsonl:1`), and its first
  chain record is not `isSidechain` and has no `agentId`. A subagent file
  carries the parent's id (`probe2-subagent.jsonl:1`), so the id check alone
  would accept it.
- **Moves.** Look again when herdr's id changes, when the file disappears, or
  when its tail holds `relocated` (`/cd` moves the file to another project
  directory). A `continued-in` record with no assistant record after it moves
  the conversation to `continuedInSessionId`; one followed by assistant
  records is history (SDK `LN`).
- **New sessions.** The hooks documentation says the transcript is written
  asynchronously, so a new session's file may not exist yet. Whether the CLI
  creates it before the first record is Not verified.

## Incremental reading

The 2.1.291 writer, by the names in its bundle:

- Records queue per file and drain every 100 ms (`FLUSH_INTERVAL_MS`), one
  append per drain. A short write is retried, so a reader can see a partial
  last line, although a 150-second sample of one live transcript saw none.
- After a crash a file can end without a newline. `sealTornTailSync` appends
  `\n` before the next write, which leaves one malformed line in the middle
  of the file.
- Removing a record (`performRemoveByUuid`) truncates the file at that line
  and writes the following bytes back, so the file shrinks and later byte
  offsets shift.
- With `CLAUDE_CODE_TRANSCRIPT_LOCAL_GC` set, the CLI may rewrite the whole
  file (`performCompactTranscript`).

In the local scan, lines reached 2.98 MB (a user record holding a base64
image result) and files 262 MB. Parents precede their children in both probe
files (no exceptions in `probe2-transcript.jsonl` or `probe2-subagent.jsonl`;
Not verified in general). A leaf found in a window over the tail of a file is
therefore the true leaf. A parent missing from such a window means older
bytes are needed, unless the window starts at the head of the file, where it
means the record was removed.

A reader therefore has to tolerate a partial last line, one malformed line
mid-file, a file that shrinks and byte offsets that move.

## Not verified

- Compaction in a capture: whether records after `/compact` parent to the
  anchor or the tail, and whether `trigger: "manual"` identifies a sent
  `/compact`.
- 2.1.291 `local_command` and `!` shell records in a capture, and
  model-invoked skill records.
- The shape of a rewind branch and of retried or fallback requests.
- How a prompt queued while busy is recorded: a user record, a
  `queued_command`, or both.
- Whether `api_error` is ever written.
- Whether the `plan_mode` attachment carries `planFilePath`.
- NFC normalization in the CLI's project key, and the long-key vectors.
- How `CLAUDE_CONFIG_DIR` changes where a herdr-managed agent writes.
- Whether `/clear` always starts a new session id and file.
- Whether parents always precede children.
- When the CLI creates a new session's file.
