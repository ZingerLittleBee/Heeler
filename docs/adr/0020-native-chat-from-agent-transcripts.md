---
status: accepted
---

# Native Chat from the Agent's own transcript

A Claude Code or Codex Agent's detail can show Chat in its terminal's place:
the Agent's conversation as native rows, read from the transcript its program
writes on the Host. Heeler reads that file read-only over SFTP on the Host's
existing SSH connection, with one adapter per program: Claude Code's project
JSONL, with its subagent transcripts under `<session>/subagents/`, and Codex's
rollout in its paginated and legacy forms. Nothing is installed on the Host
and herdr is unchanged. herdr still owns the Agent's identity and Agent
Status, submission through `agent.prompt`, and keys through `agent.send_keys`;
its `agent_session` names the transcript by a Claude Code session id or a
Codex thread id. Other Agents, and every Agent on a native Windows Host, hide
the entry. Where the design was open, T3 Code's mobile chat was the reference.

The formats as observed are recorded in
[Claude Code transcripts](../research/claude-code-transcript-format.md) and
[Codex rollouts](../research/codex-rollout-format.md); the herdr behavior Chat
relies on is in the
[versioned compatibility notes](../agents/herdr-compatibility.md).

## Entry and the terminal

A button beside Hide Composer in the Agent switcher row, and Show Chat and
Show Agent Terminal in the More menu, swap the two surfaces in place; they are
never mounted together. Terminal is the default, and a choice is remembered
app-wide. Each detail copies it when it opens, so a choice in one window does
not swap another window's screen. Chat holds no Attach. Switching to it
releases the Agent's terminal to ADR 0017's retention, where the PTY keeps
feeding the retained surface and nothing resizes it; switching back shows that
terminal, or attaches again if it was evicted. Direct Input stays on the
terminal, and ⌘E is disabled while Chat shows.

When Chat cannot show a conversation it says why and keeps the terminal one
tap away: herdr reports no session (Chat shows `herdr integration install` to
copy and never runs it), the transcript is not found or holds another session,
or it is in a form Chat does not read.

## Reading and caching

Chat follows only the session herdr reports, and only the conversation's
current branch. It opens on the last 1 MiB of the file, reads older pages as
the user scrolls up, and reads what the program appends: every second while
the Agent is Working or Blocked, while a live read shows Background Work
running, and for 15 seconds after a change, a send or a status change, every
4 seconds otherwise. Compaction keeps the history above a
separator; rolled-back turns are hidden. When a sent message has not appeared
after 10 seconds, Chat reads the Agent's record again, because the program may
have moved to a session herdr reports later. The list is a `UICollectionView`
of hosted SwiftUI rows with its own single-column layout: it opens at the
newest row and keeps the reader's place while rows above it measure, which
needs anchoring in the same main-thread turn.

Tool activity is one row per call. Decoding keeps a preview of at most
40 lines or 8 KiB; expanding a row reads its record again, at most 1 MiB, and
shows up to 1,000 lines or 64 KiB. A spilled Claude Code output is read only
from `<session>/tool-results/` beside the transcript, and a Workflow's journal
only from `<session>/subagents/workflows/<runId>/journal.jsonl`, with the run
id checked to be one `wf_` path component. Chat reads no other path a
transcript names.

Claude Code's file changes show as its terminal shows them, in the Changes
view's colors with one column of line numbers. An Edit or Write row expands to
its diff. A Bash row lists the files its command changed, from the
`bashEditDiff` Claude Code records in some permission modes: a line per file
with its path relative to the record's working directory and its counts, whose
diff opens in place up to 40 lines, with View All for the rest. A row holds at
most 40 diff lines or 32 KiB; opening more reads the record again, up to
2,000 lines or 512 KiB. Claude Code's notes stay: files named without a diff,
a skipped or unavailable diff, a command that ran beside another, and a git
step that can move the working tree. Chat looks for that step in more of a
command than the terminal does, so it may note one the terminal doesn't
rather than miss one. The terminal hides that command's hunks until its view
is expanded; Chat's diffs are closed until tapped, so it lists them under the
note.

Conversations persist in Caches with Complete file protection: decoded entries
and read cursors, never tool output or diff lines, which an expanded row
fetches again. The cache is limited to 300 MB, pruned least recently used,
drops documents unused for 30 days, forgets a Host's documents when the Host
is deleted, and can be cleared in Settings. A cached conversation opens at
once, stays readable offline, and survives the remote file's removal.

## Sending

Chat shares the terminal's Composer and its draft. Send is one `agent.prompt`
request, under rules that stand in for the screen the user cannot see:

- A draft the program would run rather than read is never sent: a leading
  `!`, control bytes, and Claude Code's whole-message `exit`, `quit`, `:q`,
  `:q!`, `:wq` and `:wq!`.
- A leading `/` must name an entry of Chat's `/` menu: the Agent's skills from
  the existing Skills probe, and `/compact` while the Agent is idle. The menu
  offers no interactive or destructive program command. Both programs show
  `/name`; a Codex skill is sent as `$name`. A leading path is text, and any
  other leading `/word` is refused with a pointer to the menu or the terminal.
- Invisible characters are removed and exactly one trailing space is appended,
  so a final `/name` or `@path` cannot leave a completion popup open when
  Enter arrives.
- Before sending, `agent.read` of the visible screen must show the program's
  input box empty, in its normal mode, with no popup. Anything else, an
  unreadable screen included, sends nothing and says why. Chat never clears
  the box.
- Three seconds after the acknowledgement the screen is read again. Text left
  in the box marks the message Not delivered. Chat never resends.

A sent message shows at once as a local echo, matched conservatively against
the transcript.

While Agent Status is Working and the draft is blank, Send becomes Stop, in
system red. In Chat, Stop presses Esc through `agent.send_keys`, in line with
the Agent page's keys; the terminal's Composer sends it on the Attach PTY (ADR
0013). Then Stop waits. The acknowledgement means only that the key reached
the PTY, and an Esc that lands after the turn ended can open the program's own
history menus, so Stop shows a spinner until Agent Status leaves Working.
After three seconds it works again and says the Agent still shows Working;
background agents and shells, which Esc does not end, can keep it there. A
failed request may still have pressed the key, so Stop then says so and works
again at once. The wait belongs to the Agent's Composer, not to a surface:
switching between Chat and the terminal, or a rebuilt detail, keeps it. With
text in the draft the button stays Send, so a prompt still queues behind the
running turn, and ⌘↩ only ever sends. A send that empties the draft keeps Stop
back for a second, so the second tap of a double tap cannot interrupt the turn
the prompt was meant to queue behind. Stop is not offered while Blocked, where
Esc answers the dialog and, on Claude Code's folder trust dialog, exits the
program.

With the keyboard down, Chat folds the Composer: the actions row goes, and Add
and Send or Stop sit beside a one-line input, a longer draft truncated after
its first line. Failure, refusal and Stop notices stay below it, and so does
the line saying Send waits for a dropped image. A tap into the input, or the
switcher row's keyboard button, opens it in full, with the caret where the
draft was left; it stays open while the tools dock is up. The status row and
the Agent switcher row stay in both. T3 Code's mobile composer folds the same
way.

## Blocked cards

While Agent Status is Blocked, Chat answers the dialog on the Agent's screen
with a native card in the Composer's place instead of sending the user to the
terminal. The screen decides what a card offers. Chat reads the visible screen
through `agent.read` with its ANSI colors, which also tell a narrow pane's
leftover text apart, and joins it with the pending request in the transcript,
a subagent's included. Labels are the program's own text.

An answer compares a fingerprint of the dialog first and sends nothing if it
changed, waits until the dialog has shown for 150 ms, presses keys through
`agent.send_keys`, and types text answers (feedback, a plan note, a custom
answer) through `pane.send_input`. The answer is confirmed when the dialog on
screen changes, when Claude Code's transcript shows the matching tool result,
or when Codex leaves Blocked. Staying Blocked proves nothing, because herdr
stays Blocked while the next queued approval takes the screen. Three seconds
without effect shows a hint, and nothing is resent. Codex holds an answer to
its asynchronous question until its next tool call, so the card confirms it by
Codex's queued-messages notice and shows it as Queued; Chat never works around
herdr's `agent_blocked` while such a question waits. A dialog the parsers do
not know gets a generic card with the Agent controls. Answers the transcript
does not record join the history as Allowed, Declined, Stopped and Answered
rows.

## Background Work

Claude Code's terminal lists background agents and Workflows under its input
box while they run. Chat lists the same Background Work over the Composer: a
Subagent the Agent tool started in the background and a Workflow, from their
launch results in the transcript and the `<task-notification>` that reports
each one's end. A row shows the work's name, its Subagent type or the phase
its Workflow is in, how long it has run, and for a Workflow the agents done
of those started. Agent counts come from the Workflow's journal while it runs,
read beside the transcript a few journals per poll, and from its notification
once it ends. A running Subagent writes nothing Chat follows, so it shows
only its time until it ends.

Running work comes first. Finished work stays, with its time and the counts
its notification reported, until the user's next prompt. The strip shows
three rows and "+N more", and condenses to one line while the Composer is open
or a Blocked card stands in its place, so the conversation keeps its room.
Every row opens a sheet listing all of it, where a Workflow opens to its
agents by the labels its program gave them. Nothing here stops work: the
terminal's own commands do that, and a stop the user cannot see confirmed
would claim more than Chat knows.

A row claims only what a read shows. With the Host away or the read failing,
running rows stop their clocks and say they are not updating. Running work
with no sign of it for longer than such work runs, two hours since a
Workflow started or its journal last changed, or three hours since a Subagent
started, says when it was last seen instead of running, and no longer holds
the faster reads. Times use the Host's clock, so a Host running ahead of the
phone reads zero.

The list is rebuilt from the loaded lines on every read, but a launch can sit
far above the tail window a later open reads. The saved conversation keeps
the list it last showed, and when its entries join the live window, work
launched above the window comes back with it: a notification or stop among
the loaded lines ends it, and otherwise it still runs. Nothing saved shows
before a live read, and a saved launch never joins a window it does not
continue, since its end could sit in the gap.

## Staging and the tools dock

Image and file staging moves from the Attach to the Agent's
`AgentComposerSession`, which the Console keeps per Agent above the detail, so
Chat and the terminal share an upload as they share the draft. This updates
ADR 0006's owner. An upload now survives pushing Changes, opening a Shell
Terminal in the detail, terminal eviction and reconnect. The last detail
leaving the Agent cancels it, and suspension ends it interrupted, with Retry.

Chat's tools dock keeps the Skills and Snippets panes, which insert into the
draft. Its Agent page presses Esc, Tab, Backspace, the arrows and Enter in the
program through `agent.send_keys`, one request at a time in the order pressed.
It has no Appearance tab and no Terminal keyboard, and a Blocked card taking
the Composer's place puts it away.

## Rationale

The transcript is the program's own record of the conversation, with structure
no screen has: message boundaries, tool calls and their results, reasoning,
subagents. It is already on the Host and readable over the connection Heeler
holds. Each alternative adds to the Host: an Agent SDK or app server runs a
second process the user did not start, and herdr serves no transcripts, so
serving them would take a change to herdr, which is not this project's, or a
plugin on every Host. Rebuilding a conversation from screen reads is what
ADR 0013 replaced with the live terminal.

Off the PTY, Chat cannot type into the TUI by accident or resize the pane under
the terminal's other clients, and its requests are the ones the terminal's
Composer already makes. A user at the terminal sees the input box and the
dialog before acting; Chat does not. It therefore reads the screen before and
after sending, refuses what it cannot check, and never resends, because a
duplicate prompt or answer does more harm than a missing one.

Staging moved because the Attach was the wrong owner. SwiftUI builds a detail
value, with a placeholder Attach, on every evaluation, and the placeholder
rebound the Composer to its own staging: a drop after a re-render, after
returning to a retained terminal, or on a first appear never started. Chat has
no Attach at all.

## Consequences

- The adapters read formats their programs do not document, and both change
  often. Unknown records are skipped, so a format change hides content until
  an adapter learns it rather than breaking Chat. The research notes record
  what each version wrote.
- Only `~/.claude` and `~/.codex` are searched; an Agent run with
  `CLAUDE_CONFIG_DIR` or `CODEX_HOME` elsewhere shows Conversation Not Found.
  Compressed (`.zst`) and pre-envelope Codex rollouts are not read.
- Claude Code writes no transcript before the first prompt, and Codex reports
  no session to herdr until after it. The Composer works in both states.
- Following makes SFTP requests on the Host's connection at every poll, and
  up to two more for Workflow journals while a Workflow is listed.
- Stop interrupts the running turn, unlike the Blocked card's Stop, which
  answers a dialog and leaves a Stopped row. Codex holding queued messages
  takes Esc as interrupt-and-send, so the Agent can stay Working.
- Chat never resizes the pane, and herdr keeps the last attached client's
  size, so cards are parsed at the phone's last grid, usually 40 to
  64 columns, where Claude Code leaves stale text.
- Conversation text now rests on the device, in the protected cache that
  [PRIVACY.md](../../PRIVACY.md) describes.
- Not in this version:
  - Chat on native Windows Hosts, and keyboard operation of cards and menus.
  - The segment before a Codex undo. After one, Chat shows only the turns
    written since; the reducer accepts the earlier segment, but nothing loads
    it yet.
  - Claude Code's session registry (`~/.claude/sessions/<pid>.json`) as a
    second Blocked signal. Cards follow herdr's Blocked alone, which reported
    every dialog the isolated-backend probes raised.
  - Skill sources the Skills probe misses: Claude Code's `.claude/commands`,
    Codex's built-in, `/etc/codex/skills`, plugin and nested `.agents/skills`
    skills. Claude Code's built-in skills are compiled into the program and
    not on disk.
  - Chat's send rules and `/` menu on the terminal's Composer, which still
    sends text as typed while the user watches the terminal.
  - Search, export, a usage meter, a command palette, a model picker, and
    editing, resending, rewinding or forking a conversation.
  - Codex's file changes beyond their counts, and a summary of the files a
    turn changed.
  - Background Work launched above the tail window of a conversation this
    device never read that far, until the user loads earlier messages past
    the launch.
  - Background Work for Codex; stopping Background Work from Chat; a running
    Subagent's progress; teammates; and a Subagent resumed through
    SendMessage, which Chat does not follow past its first end.
