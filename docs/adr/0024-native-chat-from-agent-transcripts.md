---
status: accepted
---

# Native Chat from the Agent's own transcript

A Claude Code, Codex, Pi, Oh My Pi, Grok Build or OpenCode Agent's detail can
show Chat in its terminal's place: the Agent's conversation as native rows,
read from the transcript its program writes on the Host. Heeler reads that
file read-only over SFTP on the Host's existing SSH connection, with one
adapter per program: Claude Code's project JSONL, with its subagent
transcripts under `<session>/subagents/`; Codex's rollout in its paginated and
legacy forms; Pi/Oh My Pi's v2-v3 tree JSONL; and Grok Build's
`updates.jsonl`. OpenCode 2.x writes no transcript file, so Chat reads its
session's rows from OpenCode's own SQLite database with a bounded read-only
query on the Host instead;
[ADR 0025](0025-opencode-chat-reads-its-session-store.md) records that read
path and how Chat tells when OpenCode has left the conversation herdr reports.
Nothing is installed on the Host
and herdr is unchanged. herdr still owns the Agent's identity and Agent
Status, submission through `agent.prompt`, and keys through `agent.send_keys`;
its `agent_session` names the transcript by a Claude Code session id, a
Codex thread id or a Grok Build session id, or Pi/OMP's exact absolute JSONL
path (with UUID lookup for older integrations), or an OpenCode `ses_` id.
Other Agents, and every Agent on a native Windows Host, hide the entry.

The formats as observed are recorded in
[Claude Code transcripts](../research/claude-code-transcript-format.md) and
[Codex rollouts](../research/codex-rollout-format.md); the herdr behavior Chat
relies on is in the
[versioned compatibility notes](../agents/herdr-compatibility.md).

Pi/OMP observations are in [Pi transcripts](../research/pi-transcript-format.md).
Their adapter follows `parentId` from the latest selected leaf, including
invisible state records. A live Pi/OMP window never prepends unproven cached
history: that prefix may belong to a branch the user abandoned. Offline cached
conversations still restore; online earlier history is loaded from the file.
Custom session directories work when herdr reports the file path. UUID-only
lookup stays within `.pi/agent/sessions` or `.omp/agent/sessions`.
Pi and OMP report a new session's path at startup but write the file with
its first reply, so a reported path with no file, or an empty one, is a new
conversation: Chat shows it as empty, looks again on every poll without
backing off, and keeps a sent message's echo waiting rather than overdue.
Claude Code reports a new session's id at startup and writes the file with
its first message, and herdr does not pass on the path. A Claude session
with no file in any project directory is new when
`~/.claude/session-env/<id>/` exists: Claude Code makes it before running
the SessionStart hook that reports the session. Chat shows it as empty too,
and looks again on every poll under the Agent's directories alone, searching
every project directory again only when herdr reports another status, as a
prompt brings. Claude Code records a message as it takes it, so that echo
still times out, and a session that leaves a message from Chat unrecorded
past that timeout saves nothing: Chat shows it as Not Found. Once a file was
followed or saved on the device, its absence is Not Found.
OMP sometimes rewrites its file atomically, filling in the session header,
so a Pi/OMP file is identified by its header's session id rather than its
first bytes, and Chat's sends are confirmed by entry: a rewrite neither
drops the saved conversation nor confirms a send twice.
A message that steers a running turn (Oh My Pi's `steering` flag, or a Pi
prompt written within moments of the turn's tool results) shows inside that
turn, marked Sent while working, instead of interrupting it, and still
confirms Chat's send.
A prompt typed after resuming a turn whose process died opens a turn of its
own.

Pi's stock rule editor and OMP's rounded box require a visible software cursor.
Pi's empty editor is one row between its rules, directly above a footer whose
working-directory row is followed by a context-usage stats row; any row
between the editor and that footer is a completion list. While a turn runs,
Pi sets a braille spinner and label into the top rule (`── ⠸ Working ───`);
that editor still takes a message, which steers the turn.
OMP's status-band composer is recognized by its filled header, percentage
gauge and `╰─` prompt even when herdr omits the hardware cursor. Only the
header's idle glyph (`π > ` in the 18.10.4 unicode preset, U+F0D57 in the
18.11.1 nerd preset) lets Chat send. A braille spinner there means a turn is
running, so Chat holds the message rather than steer it; an approval or ask
panel resting on the band also holds it. The italic first-message hint on the
prompt row is not a draft.
Drafts, completion popups and other editor shapes stay in the terminal.
OMP's tool approval and single-select question get Blocked cards (see Blocked
cards); any other titled OMP panel ending the screen or resting on the band,
such as the plan review, holds sending, and Pi's extension dialogs stay in
the terminal. Neither program reuses Claude/Codex option digit bindings.
Their `/` menu and shell-command refusals use the same Chat send rules as the
existing adapters.

Grok Build observations are in
[Grok Build transcripts](../research/grok-build-transcript-format.md).
herdr reports a Grok Build session by the lowercase UUIDv7 that names its
folder, and Chat reads only that form, as given. The adapter looks for
`<group>/<id>/updates.jsonl` under `~/.grok/sessions`, where the group is the
Agent's directory percent-encoded as Grok Build names it or, past 255 bytes,
a slug whose `.cwd` file holds the directory. A session forked into a
worktree files under the worktree's group while herdr still reports the
pane's directory, so the other groups follow, worktrees first, up to 200; a
file counts only when its first record names the session. Entries are keyed
by byte offset, never by Grok Build's event ids, which a fork copies. Ctrl+C
before a turn's first output puts the prompt back in Grok Build's input box
and writes no end, so once herdr reports the Agent idle, a turn that holds
only its prompt ends as stopped before a reply; the next prompt is recorded
under the same index, joined with the text put back, and takes that turn
over. A `rewind_marker` hides the turns from its target prompt on, even when
the loaded lines start after that prompt. Grok Build writes a prompt sent
while it works only when that prompt's turn starts, and herdr reports it
Working for a whole `/compact`, so a sent message's 10 seconds count only
while herdr reports the Agent neither Working nor Blocked.

Grok Build's input box is the bottom-most rounded box whose first row starts
with its `❯` prompt. Chat sends only when the box holds no typed text and the
footer shows it has focus (`Shift+Tab:mode` or `accept suggestion`), or from
the Welcome screen; the italic suggestion Grok Build draws is not a draft.
At 20 rows or fewer, as on a phone with the keyboard up, Grok Build's compact
footer is only `Ctrl+.:shortcuts` whatever has focus, so there an empty box
without the `Build anything` placeholder, which it draws only without focus,
counts as focused. The same holds in the dashboard's view of one agent, whose
own hints come first and stop before `Shift+Tab:mode` at a phone's 62 columns;
its box is read like the conversation's own, and the session check below
decides whose agent it shows.
Its dashboard, where a message starts a new agent, its pickers, popups and
`/btw` panel, a pending second key press, `/multiline`, a queued message being
edited, shell and remember modes, minimal mode, and a wait on a subagent or
background task, which a message would cancel, all hold the message. A card
the dashboard's view shows stays generic. Stop presses nothing in that view,
which stays until Grok Build restarts. Where Ctrl+C there would confirm a
pending quit, quit while a cancel is pending, or only clear a draft, Stop
says so as it does on the conversation's own view; otherwise it says to stop
the turn with Ctrl+C in the terminal. Grok Build can put a stashed draft
back in the box right after it takes a message, so only text the message
contains marks it Not delivered; other text holds the next send.

herdr follows Grok Build's `/new`, `/clear` and a message sent from its
dashboard, but keeps the earlier session after `/resume`, `/fork` and going
back from the dashboard, and Chat follows herdr. At Grok Build's start a
message from the Welcome screen went to the session herdr reported, but on
the Welcome screen `/welcome` opens later, text sent there started a new
session first, which herdr then reported (1.0.62): a message then ran in it,
and a `/resume` left herdr on it, empty, while the screen showed the resumed
session. The Welcome screen's Resume session picker (Ctrl+R) started no
session, so the hold there names it as the way back. The screen read that
checks the input box before a send therefore also holds the message when it
shows a `Session <id>` line for another session, a newest message the
conversation doesn't have (only once herdr reports the Agent idle and a
transcript read since then has landed), or the Welcome screen of a
conversation that already has messages. A conversation with no message yet
has none of its own on screen, so there any message shown, a command or a
chip aside, holds the send; herdr can report a new session before Grok Build
writes its first prompt, and a send in between holds until a read finds that
prompt. Once the dashboard opened an agent, Grok Build kept the dashboard's
view of one agent, also after `/resume` and leaving the dashboard, until it
restarted (1.0.62); that view takes a message only when the check finds this
conversation's newest message there, and holds it otherwise, also while
herdr reports no session. Such a hold reads the Agent's record again, so a
`/new` herdr has just reported is followed. Nothing is read from the Host
between that screen read and the prompt. At 20 rows or fewer Grok Build
draws the user's messages without their `❯`, so there the screen shows no
newest message, and unless a `Session <id>` line for another session shows,
only the read after a send catches a message another session took. In the
dashboard's view of one agent nothing on screen can then prove the
conversation, so Chat holds every send there whenever it recognizes that
view at that size, even while it shows this conversation; no capture shows
whether the view keeps its `‹ i/n ›` header and `Ctrl+\:dashboard` footer at
20 rows. The way out is to show the terminal with the keyboard down, which
gives the pane more than 20 rows (41 rows on the phone, as measured), or to
restart Grok Build. After a send, Chat reads what Grok Build added to the
folder's `prompt_history.jsonl` since just before the send, up to 64 KiB:
two seconds after a message delivered while herdr reported the Agent neither
Working nor Blocked, and again when the message would go overdue. When no line
with the message's text names this session and exactly one names another, the
message reads "Sent, but the Agent recorded it in another session.", and every
later send is held until this conversation records a prompt, a send's screen
check finds this conversation's newest message (not one that reads the same as
a message recorded elsewhere), that message is recorded here after all, or
herdr reports another session. That message's echo leaves when this
conversation records a later prompt, usually at the read that also ends the
hold, rather than stay below the turns after it. A prompt with the same text
recorded here is matched to that message only when no other message from Chat
takes it, so the text sent again from Chat is matched to the new message. A
`/resume` to a session already open writes nothing until its next prompt, so
only that read tells, after the send. A session filed under another
directory's group, such as a worktree fork, records its prompts in that
group's file, so a message sent to it only goes overdue. Chat doesn't watch
the screen between sends.

## Entry and the terminal

A button for the surface not showing, sharing the detail header's More-menu
capsule whether the header is folded or not, and Show Chat and Show Agent
Terminal in the Composer's More menu, swap the two surfaces in place. The
button keeps the switch out of the Agent switcher row, whose chips and
keyboard buttons fill a phone's width. The surfaces are never mounted
together. Terminal is the default, and a choice is remembered app-wide. Each
detail copies it when it opens, so a choice in one window does not swap
another window's screen. Chat holds no Attach. Switching to it releases the
Agent's terminal to ADR 0017's retention, where the PTY keeps feeding the
retained surface and nothing resizes it; switching back shows that terminal,
or attaches again if it was evicted. Direct Input stays on the terminal, and
⌘E is disabled while Chat shows.

When Chat cannot show a conversation it says why and keeps the terminal one tap away: herdr reports no session ID, the transcript is not found or holds another session, or it is in a form Chat does not read. A missing session ID does not establish whether the integration is installed, so Chat waits for the identity and offers Check Again without an installation command. A failed Agent query appears as a read failure, preserves any messages already shown, and retries; a successful query clears only its own failure, leaving transcript read failures visible.

## Reading and caching

Chat follows only the session herdr reports, and only the conversation's
current branch. It opens on the last 1 MiB of the file, reads older pages as
the user scrolls up, and reads what the program appends: every second while
the Agent is Working or Blocked, while a live read shows Background Work
running, and for 15 seconds after a change, a send or a status change, every
4 seconds otherwise. Compaction keeps the history above a
separator, which previews the program's Markdown summary as plain lines and
reads only its three preview lines aloud; rolled-back turns are hidden. When a
sent message has not appeared after 10 seconds, Chat reads the Agent's record
again, because the program may have moved to a session herdr reports later. A
Pi or Oh My Pi `/compact` waits for one screen read first, and keeps waiting
while that read shows its compaction running ("Compacting context..."), which
herdr reports as idle; the 10 seconds then count from the last read that saw
it. While Chat shows an idle Agent,
it reads the record at its idle poll, at least 5 seconds apart (about every
8 seconds at the 4-second pace): Claude Code's `/clear`, Pi's and Oh My
Pi's `/new` and `/resume`, and Grok Build's `/new` and `/clear` typed in the
terminal move the Agent to another session, and no event says so. Codex
reports a new thread only with its
first prompt, when the Agent is working again. Hidden and working Chats
don't read it on that pace. The
list is a `UICollectionView`
of hosted SwiftUI rows with its own single-column layout: it opens at the
newest row and keeps the reader's place while rows above it measure, which
needs anchoring in the same main-thread turn.

Earlier history loads by itself as the reader nears the top of the list. Each
request reads pages until it brings the start of a turn not shown before,
since a page that ends inside a turn adds only steps its fold hides, or until
it reaches the start of the file or has read 32 MiB. A request the list makes
by itself reads as one from Load Earlier Messages does, except in Grok Build,
where it reads at most 4 MiB. Grok Build records each `read_file` result in
full, so one turn can fill tens of MB: a turn that read 21 files of 99,000
bytes and compacted automatically three times wrote result lines of about
402 KB and grew its file from 62 KB to 34.2 MB. When those 4 MiB end inside
one turn, the list stops asking, and Load Earlier Messages reads on with the
32 MiB search. The list loads by itself again once a tap brings a turn's
start or the conversation opens again.

Tool activity is one row per call, and two or more calls in a row share a
group row (see Turns and tool groups). Decoding keeps a preview of at most
40 lines or 8 KiB; expanding a row reads its record again, at most 1 MiB, and
shows up to 1,000 lines or 64 KiB. A spilled Claude Code output is read only
from `<session>/tool-results/` beside the transcript, and a Workflow's journal
only from `<session>/subagents/workflows/<runId>/journal.jsonl`, with the run
id checked to be one `wf_` path component. Chat reads no other path a
transcript names. Beside a Grok Build session's folder it reads one more
file, the group's `prompt_history.jsonl`, and only what it gained since
just before a send, at most 64 KiB. Those lines can hold prompts from other
Grok Build sessions in the same directory; Chat compares them with the sent
message in memory and discards them, never caching, logging or showing
them.

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

Pi and Oh My Pi edits list the files their results record, shown the same
way: Oh My Pi's numbered diff without hunk headers, one per file under
`perFileResults` when an edit changed several, and Pi's unified patch, whose
path comes from the call.

Conversations persist in Caches with Complete file protection: decoded entries
and read cursors, never tool output or diff lines, which an expanded row
fetches again. The cache is limited to 300 MB, pruned least recently used,
drops documents unused for 30 days, forgets a Host's documents when the Host
is deleted, and can be cleared in Settings. A cached conversation opens at
once, stays readable offline, and survives the remote file's removal.

Each Host also keeps its Chat entry points: the Agents last seen and the
conversation each was bound to, so an offline Console still lists them and a
live Agent that has not reported its session reopens the right one. An entry
listed while its Host is unproven is removed on the device, with its cached
conversation and pin, never through a close request; a later snapshot lists
the Agent again if it still runs. Those bindings belong to one machine and herdr session. The machine is the host
key the device trusts for the Host (ADR 0022), not a route: routes may be
added, reordered, or edited freely, but a replaced key, a changed account, or
another herdr session drops them. So does another Herdr Endpoint socket,
which names another herdr server; a changed launcher keeps them. Because
trusting a replaced key leaves the Host record unchanged, every new
connection re-proves the saved bindings before live Agents can use them. A
Host the device holds no key for yet, and directories saved before the Host
had one, compare the primary route instead.

Image tool rows with a recorded Host file path offer a native long-press preview. Tapping the preview opens a zoomable sheet. Paths come from transcript metadata, resolving relative paths only against the recorded working directory; display titles are never treated as paths. Reads use the existing read-only SFTP connection on demand, stop at 20 MiB, and decode off the main actor to at most 4,096 pixels on the long edge. Image bytes are not cached with transcripts. Missing, changed, unsupported or disconnected files show a retryable explanation.

## Sending

Chat shares the terminal's Composer and its draft. Send is one `agent.prompt`
request, under rules that stand in for the screen the user cannot see:

- A draft the program would run rather than read is never sent: a leading
  `!`, control bytes, and Claude Code's and Grok Build's whole-message
  `exit`, `quit`, `:q`, `:q!`, `:wq` and `:wq!`. Oh My Pi also refuses its
  whole-message `exit`, `quit` and `q` in any case, a leading `$` or `$$`
  and whitespace (Python), a whole `.` or `c` (Continue), a leading `->` or
  `=>` (its queue shorthand), and 100 lines or more, which open its paste
  menu. For Grok Build, a `/btw` or `/goal` after the message's start is
  refused too: Grok Build would make the message a side question kept out
  of the conversation, or refuse it and leave it in its input box. OpenCode
  refuses Claude Code's words, which cover its own `exit`, `quit` and `:q`,
  and a draft that is only file paths, which OpenCode can take as
  attachments instead of text; a few words before the path send it as text.
  The refusal says to start with them: with words only after an absolute
  path, as Add Image and Add File leave one, the draft is refused as a
  command path (below).
- A leading `/` must name an entry of Chat's `/` menu: the Agent's skills from
  the existing Skills probe, and `/compact` while the Agent is idle. The menu
  offers no interactive or destructive program command. Every program shows
  `/name`; a Codex skill is sent as `$name`. For Pi and Oh My Pi the menu, and
  Chat's Skills list, hold only `/skill:` skills, sent as `/skill:name` (typed
  that way too); prompt templates stay out because one named like a built-in
  runs the built-in. A Claude Code skill whose `SKILL.md` frontmatter says
  `user-invocable: false` stays out too: Claude Code 2.1.302 answers
  "Unknown command" when it is typed. Codex's `allow_implicit_invocation` and
  Pi's `disable-model-invocation` limit only the model, so their skills stay.
  Grok Build runs its built-in command when a skill shares its name, so the
  menu leaves such skills out there, and a Grok Build `/compact` with a
  focus is refused.
  OpenCode's menu holds only `/compact`: its skills have no form a message
  can invoke, and its server and custom commands are not offered.
  A leading path is text, and any other leading `/word` is refused with a
  pointer to the menu or the terminal. OpenCode names a custom command by its
  file's path (`/git/commit`) and runs a message that starts with one, so
  there a leading `/word` with a slash in it is refused too.
- Invisible characters are removed and exactly one trailing space is appended,
  so a final `/name` or `@path` cannot leave a completion popup open when
  Enter arrives. Oh My Pi's and OpenCode's `/compact` are the exceptions:
  they go without the space, which Oh My Pi would complete to
  `/compact soft` instead of running it and OpenCode would send to the model
  as a message, and with a focus or instructions they are refused.
- Before sending, `agent.read` of the visible screen must show the program's
  input box empty, with nothing over the box that would take the keys.
  Anything else, an unreadable screen included, sends nothing and says why.
  Chat never clears the box.
- herdr does not report OpenCode's `/new` or `/clear`, so before an OpenCode
  send Chat also reads the Agent's record again and compares the terminal
  title with the conversation's title (ADR 0025). It sends nothing, and says
  why, when herdr now reports another conversation, which Chat then switches
  to, when Chat already shows that OpenCode is on its home screen, when the
  title names another conversation, or when the check itself fails. Right
  after `/new`, before Chat shows that, the screen read above finds the home
  screen and holds the send instead.
- Three seconds after the acknowledgement the screen is read again. Text left
  in the box marks the message Not delivered. Chat never resends.

A sent message shows at once as a local echo, matched conservatively against
the transcript.

While Agent Status is Working and the draft is blank, Send becomes Stop, in
system red. In Chat, Stop presses the program's Stop keys in one
`agent.send_keys` request, in line with the Agent page's keys: Esc, except in
Grok Build (below), or Esc twice for OpenCode, whose first Esc only arms its
interrupt. Before OpenCode's, Chat reads the screen and presses nothing unless
it shows the conversation's prompt with a turn running and no dialog, menu or
shell mode over it, where Esc would do something else. The terminal's
Composer sends one Esc on the Attach PTY (ADR 0013). Then Stop waits. The
acknowledgement means only that the keys reached the PTY, and an Esc that
lands after the turn ended can open the program's own history menus, so Stop
shows a spinner until Agent Status leaves Working. After three seconds it
works again and says the Agent still shows Working; background agents and
shells, which Esc does not end, can keep it there. OpenCode's interrupt
resumes with a message that waited during the turn: OpenCode records the
stopped turn as interrupted and starts that message within milliseconds, and
herdr 0.9.5 reports idle for about 105 ms before Working again. That idle
ends Stop's wait, so Stop is ready again at once, and a second tap stops the
resumed run. OpenCode's notice, which mentions such a message, remains for a
stop that does not take effect. A failed request may still have pressed the
keys, so Stop then says so and works
again at once. The wait belongs to the Agent's Composer, not to a surface:
switching between Chat and the terminal, or a rebuilt detail, keeps it. With
text in the draft the button stays Send, so a prompt still queues behind the
running turn (Pi and Codex 0.162.1 steer the turn with it), and ⌘↩ only
ever sends. Oh My Pi
and OpenCode are the exceptions. A steer in Oh My Pi can move a running
command to the background, and herdr writes Enter 300 ms after the paste
whatever OpenCode shows by then, so a permission or question OpenCode raises
in between would take it as its answer (ADR 0025). While Oh My Pi's status
band or OpenCode's footer shows a turn running, Chat holds the message and
says to send once it is idle or steer from the terminal. Esc in
Pi or Oh My Pi puts a steer the turn has not taken back into the input box,
and Esc in Codex 0.162.1 does the same with a follow-up queued with Tab, so
a draft found there says Stop may have left it. A send that empties the draft keeps Stop
back for a second, so the second tap of a double tap cannot interrupt the turn
the prompt was meant to queue behind. Stop is not offered while Blocked, where
Esc answers the dialog and, on Claude Code's folder trust dialog, exits the
program.

Grok Build cancels a turn only with Ctrl+C; Esc there shows a toast. Ctrl+C
also clears a draft, cancels a permission, skips a question, and on an idle,
empty input box arms quit, which a second press within a second carries out.
So Chat's Stop reads Grok Build's screen first, inside the same key queue
after any key pressed before it, and presses Ctrl+C only when herdr reports
Working and the screen shows the turn's spinner row or its `Ctrl+c:cancel`
hint, with the input box empty and focused and no card, menu, pending cancel
or pending second press; otherwise it presses nothing and says why. Two of
its presses are at least 1.5 seconds apart, even across status changes, so
they never fall in one quit window. Ctrl+C with messages queued starts the
next one, so Stop may then say the Agent still shows Working. The terminal's
Composer keeps Send for Grok Build, since Esc wouldn't stop it.

With the keyboard down, Chat folds the Composer: the actions row goes, and Add
and Send or Stop sit beside a one-line input, a longer draft truncated after
its first line. Failure, refusal and Stop notices stay below it, and so does
the line saying Send waits for a dropped image. A tap into the input, or the
switcher row's keyboard button, opens it in full, with the caret where the
draft was left; it stays open while the tools dock is up. The status row and
the Agent switcher row stay in both.

## Blocked cards

While Agent Status is Blocked, Chat answers the dialog on the Agent's screen
with a native card in the Composer's place instead of sending the user to the
terminal. The screen decides what a card offers. Chat reads the visible screen
through `agent.read` with its ANSI colors, which also tell a narrow pane's
leftover text apart, and joins it with the main conversation's pending
request in the transcript; a subagent's dialog is read from the screen alone.
Labels are the program's own text. herdr reports Claude Code idle on some of
its question pages, the review page of a question form and a question with
previews, so while the transcript holds an open AskUserQuestion call, an idle
Claude Code's screen is read for a card as a Blocked one is, though a screen
with no dialog then shows no card rather than the unreadable one.

An answer compares a fingerprint of the dialog first and sends nothing if it
changed, waits until the dialog has shown for 150 ms, presses keys through
`agent.send_keys`, and types text answers (feedback, a plan note, a custom
answer) through `pane.send_input`. The answer is confirmed when the dialog on
screen changes, when Claude Code's transcript shows the matching tool result,
or when Codex, Oh My Pi, Grok Build or OpenCode leaves Blocked. Staying
Blocked proves nothing, because herdr stays Blocked while the next queued
approval takes the screen.
Three seconds without effect shows a hint, and nothing is resent: the card's
answers stay disabled while the same dialog shows and no call that waited
has resolved, so a second tap cannot send the key again, and Stop and the
terminal stay available (the open card shows Stop then, even beside a
decline option). Grok Build draws identical cards for parallel subagents
with one description, with herdr Blocked between them, so there only a call
the card could be answering that waited when the keys went out brings the
answers back, once it starts or resolves, and it also drops the hint: Grok
Build writes a call's start only once it runs, while the other programs read
an open call as waiting or running from herdr's status alone. A command,
file or question card could be answering the calls it matches, and a
subagent's card the spawns its `Allow <description>?` names, whole or cut
at the card's edge; a card that matches none, any call that waited. Another
call starting or resolving, such as the previous card's call read late or a
call that needs no approval, which also reads as waiting while herdr reports
Blocked, shows nothing about the answer. Codex
0.160.1 holds an answer to its asynchronous question until its next tool call,
so the card confirms it by Codex's queued-messages notice and shows it as
Queued. Codex 0.162.1 delivers the answer at once (a waiting `write_stdin`
returns early) and draws no notice, so the question leaving the screen
confirms the answer too, and it still joins the history as Queued. Chat
never works around herdr's
`agent_blocked` while such a question waits. Oh My
Pi's tool approval binds no digits and ignores its approve key for 500 ms
after it draws, a span that starts before Chat first sees it: Approve presses
ctrl+q once the panel has shown for 650 ms, and Deny presses Esc, after which
Oh My Pi goes on with the turn. ctrl+enter is never sent, since without kitty
keys it reads as Enter. Oh My Pi 18.12 also lists Approve, `Approve <tool> for
this session` and Deny under the details. When the panel lists the session
row, the card offers it as a third button with a caption saying Oh My Pi won't
ask again for that tool in the session. The row has no key of its own, so the
card reads the list's pointer, moves one arrow key per row with a focus check
after each, as on a question, and presses Enter, which shares the 500 ms arm;
a pointer it can't read, or one that doesn't move, stops it before Enter.
While Oh My Pi's prompt holds a draft the pointer marks Deny and the arrow keys
edit the draft, so the session button sends nothing and says to clear it;
Approve and Deny keep their keys. Oh My Pi's single-select question ignores
digits, so its card moves one arrow key per row, checks the focus after each,
and presses
Enter. Several questions are answered page by page, each page its own card,
then the review page's Submit; an answer is confirmed by the `ask` result or
by the next page. While Oh My Pi's prompt holds a draft, keys would go into
it, so the card answers nothing but Stop and says to queue or clear the draft
in the terminal. Stop on an Oh My Pi question presses Esc, which cancels the
question and ends the turn, and the card says so. Grok Build's permission
card, its single question, `/fork`'s worktree question and the stop panel
Ctrl+C opens while subagents run get cards. Each answer presses its row's
own key, a digit or a question's letter, which selects and submits at once;
Esc, Ctrl+C and letters on a permission card, which open the reject row's
feedback field, are never pressed. The permission card offers Yes, proceed
(Yes on an edit), `Always allow: <command>` and Yes, allow all edits during
this session, each persistent row with a caption saying what Grok Build
keeps, and Deny, which presses the reject row and ends the turn; the
always-approve mode and Never allow rows stay in the terminal. So does a
lasting rule Grok Build cut to fit with `…`, as at 40 columns, since the cut
hides how far it reaches; the card then says to widen the terminal to see
it. Grok Build asks the same way before a subagent starts, under the card's
own question, `Allow <description>?`, and there Yes, send once approves that
subagent alone. The Agent wrote that question, so the card's title shows
all of the question Grok Build drew, with no line limit, and the card does
not repeat it, also where Grok Build cut it with `…`. The stop panel offers
Stop running and Continue to run,
which ends the turn while the subagents go on; Always stop and Always
continue write the config and stay out. The worktree question `/fork` asks
gets its own card: Yes and No, each of which forks; Always worktree and
Never worktree, which save the choice, stay in the terminal. The card says
that Chat stays with this conversation and holds messages until `/resume`
switches back to it, since herdr keeps the parent session. A card too
narrow to show No, as at 40 columns, stays generic with its key pad, and
says that every answer forks and that the rows out of view save a lasting
choice. Neither the questions nor the stop panel offers Stop, since Esc
there only moves Grok Build's focus or keeps the turn running. After Esc,
Grok Build's focus rests in its scrollback, where keys miss the card, so the
card then answers nothing and says to answer in the terminal. Grok Build's
other cards, such as the rewind confirmation, get the generic card without
numbered answers. Multi-select questions, option notes and typed answers
stay in the terminal. A dialog the parsers do not know gets a generic card
with the Agent controls. Answers the transcript does not record join the
history as Allowed, Declined, Stopped and Answered rows.

OpenCode draws a permission or question in its input box's place. A
permission's options sit in a row: Allow once has focus and takes Enter,
Always allow, when offered, is one checked Right step and Enter, and Reject
presses Esc. Always allow saves a project rule that can reach past the
request (every read, or every command starting with the same words), and
the card says so. A shell command's permission has no action row and a
subagent's names only the agent, so the fingerprint also covers the lines
about the request (`$ git status`). While Always allow has focus OpenCode
shows the rule in their place, so a card answers only a screen showing the
lines it shows, and the checks between and after its keys accept either
set. OpenCode draws its subagents' requests there too, and Esc on one
of them asks what to do differently instead of rejecting, so the card
rejects only a request it matches to a pending call of the conversation it
follows and otherwise says to reject in the terminal, where that feedback
page stays. A single question's digit picks its answer and submits it, and
Dismiss presses Esc for a matched call. The card names Esc there as
OpenCode's footer does (`esc dismiss`), open or folded, though dismissing
also ends OpenCode's turn, as it does in the terminal. Several questions,
multi-select questions and typed answers stay in the terminal. herdr also reports
OpenCode Blocked with no dialog on screen, as for a failed turn, and there
the generic card's keys would act on OpenCode's prompt: Up recalls the last
prompt for Enter to send again, Down opens the subagent panel, and Enter on
an empty box sends a queued prompt. OpenCode's card for a screen with no
dialog therefore shows no keys. It says why OpenCode is Blocked, the subagent
panel covering the request, the turn's error, or a likely failed model
request, and points to the terminal.

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
running Background Work rows stop their clocks and say they are not updating.
Running work
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

## Turns and tool groups

A long turn of tool calls is hard to read back, so Chat folds what a finished
turn did behind one row and keeps its answer in view. A turn runs from the prompt, command or
notification that opened it to the next one, as the program records it:
Claude Code from its user records, or a local command or visible message
between turns, to its `turn_duration` or interrupt marker, Codex from its
turn events. A Claude Code turn whose last reply is an API error failed.
The newest turn runs while a live read backs it, herdr reports the Agent
Working, Blocked or unknown, and no record has closed it; every other turn is
finished. A message
sent from Chat opens no turn of its own, since the program may hold it until
the running turn ends, and shows after every turn. When the loaded lines
start inside a turn, the saved record of that turn takes the end they give
it. A running turn shows "Working for 1:05" under its prompt, counted
from its first record on the Host's clock.

Timeline rows read as last seen while nothing live backs them: with the Host
away or the conversation read from the cache, the newest turn stops running
(it stays open, without a clock, while listed Background Work runs), and a
running tool, Agent or Workflow row says Running when last seen instead of
spinning. A failed read alone keeps them live.

A finished turn keeps its prompt, the rows it pins and its final answer, the
model's text at its end. Everything between folds behind one "Worked for 35s"
row above the answer, wall time from the record that opened the turn to the
one that closed it (Claude Code's `turn_duration` or interrupt marker,
Codex's turn-complete event), or "Details" when the records give none. Pinned rows stay above that row: plans,
questions, messages sent while working, compaction separators, task notifications,
interruptions, stops, errors, calls waiting on the user, and Subagent
launches. A turn with nothing before its answer, with no answer, or that was
interrupted or failed does not fold, and neither does the newest one while
Background Work runs. A Codex call recorded after its turn completed, a
command left running as a background terminal, folds with the steps above
the answer rather than unfolding the turn. Opening a fold opens none of the rows or groups inside
it; the model's text there reads in the secondary color. Fold Finished
Turns in Settings turns folding off.

Rows above the first loaded turn belong to a turn whose start is further up,
and show as they load while earlier history still loads by itself. Once it
waits for Load Earlier Messages, which only Grok Build's does (see Reading and
caching), they read as a finished turn as far as they are loaded: the end the
loaded lines record closes it, and its header shows the time that end gives
(`elapsed_ms`), or "Details" without one.

Two or more consecutive tool calls show as one group row: the first call's
symbol, what the calls did ("Ran 2 commands, Edited 2 files", files counted
once per path, a write over an existing file as an edit, a write that records
no diff as written, a path changed more than once under its first change while
reads count apart), their lines changed, and a spinner or a count of failures.
Reasoning between calls joins the group; reasoning with no text shows
nowhere. Subagent launches, questions, calls waiting on the user and Codex's
user shell commands are never grouped. While a turn runs, its last group
keeps its newest call as its own row below the group, so its status and
output stay in reach, and settles into one row, under a new identity and
closed, once anything else follows. A call waiting on the user after the
group keeps it live, with every call inside, so the group keeps its identity
through the dialog.

Codex collaboration events with the same full Subagent path share one pinned card within a turn, stopping at a user message or divider. The card keeps its first row identity, shows a Lucide Bot icon beside its title and identifies the Subagent to VoiceOver, and opens to the full path and recorded history. Consecutive repeated events show a count. The latest event describes recorded activity, not live worker status: a message exchange is never shown as completed work. Missing identities stay separate, and copying a card includes its path and history.

Folding is a projection of the built rows, made on the main actor each time
rows or an open header change, so a header opens or closes in the same
main-thread turn as the tap. The header keeps its top edge, even while the
list follows its end; a row folded away under the reader puts its header
where the row was. Nothing about what is open is saved, and folded rows keep
their measured heights and what they have open.

A floating Collapse Steps control is available when the reading viewport
intersects a turn with open reasoning, tools, file diffs or group headers.
It closes that turn's disclosures together, including remembered child
disclosures, and leaves other turns alone. A finished turn folds behind its
header; a running or interrupted turn keeps its narration and compact rows.
The collapsed header replaces the reader's position where content permits;
near the end, the offset clamps to the natural content boundary so no artificial
blank space follows the last row. Jump to Latest resumes following. This action changes
only presentation; it never stops the Agent.

While the control shows, the list reserves its height as bottom inset. A list
that rests with its end under the control, or past the bottom edge by no more
than that reserve (a short last turn just opened), moves to its end so the
newest rows sit above the control and take taps. Further from the end the
reader is scrolling a long turn, and the reserve lets its last row scroll
clear.

Markdown tables retain their original source for selection and use Foundation's
parsed row and column coordinates for display, including empty cells and column
alignment. Inline formatting and the existing link policy apply inside cells.
Columns share widths across rows and cells wrap; only a table wider than the
available space scrolls horizontally within the message.

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
- Claude Code and Codex transcripts are looked for only in `~/.claude` and
  `~/.codex`. herdr learns the session from integration hooks in the
  program's config directory, so an Agent run with
  `CLAUDE_CONFIG_DIR` or `CODEX_HOME` elsewhere reports none without them
  there, and Chat shows Waiting for Conversation; with them installed there,
  Chat shows Conversation Not Found.
  Compressed (`.zst`) and pre-envelope Codex rollouts are not read.
  Grok Build sessions are looked for only under `~/.grok/sessions`: a
  custom `GROK_HOME` lives in the Agent's environment, which herdr does not
  report, so a session there is not found.
- Claude Code writes no transcript before the first message. Chat tells a
  new session by its `session-env` directory under `~/.claude`, so a Claude
  Code that makes none shows Conversation Not Found until then; one run with
  `CLAUDE_CONFIG_DIR` elsewhere is not found at all, as above. A Claude Code
  that saves no transcript, such as with `CLAUDE_CODE_SKIP_PROMPT_HISTORY`,
  shows No Messages Yet until a message sent from Chat goes unrecorded.
  Codex reports no session to herdr
  until after its first prompt, also after a resume, by id or by name, or a
  restart in its pane. The Composer works in all these states.
- Following makes SFTP requests on the Host's connection at every poll, or,
  for OpenCode, one exec per poll (ADR 0025). While
  a Workflow is listed, each poll also looks at up to two journals: a stat
  each, and for one that grew, reads of what it added, up to 128 KiB.
- So that cached conversations open at once, after each connect the Console
  reads every listed Agent's transcript once, with its Chat hidden, and again
  when the Agent's status changes; OpenCode's, which would cost an exec each
  time, is read only by an open Chat. A missing one is looked for a few times,
  then not again until the Agent's status or session changes or the Host
  reconnects; an open Chat keeps looking on its own.
- Stop interrupts the running turn, unlike the Blocked card's Stop, which
  answers a dialog and leaves a Stopped row. Codex 0.162.1 records a Chat
  send during a turn at once, as a steer, so Esc only aborts the turn and the
  steer goes unanswered; a follow-up queued with Tab in the terminal goes
  back into the composer, where Chat's next send holds on it.
- Chat never resizes the pane, and herdr keeps the last attached client's
  size, so cards are parsed at the phone's last grid, usually 40 to
  64 columns, where Claude Code leaves stale text.
- Folding trusts the programs' turn records. A turn no record closes, such as
  one Claude Code wrote no `turn_duration` for, finishes only when herdr
  reports the Agent idle or nothing live backs it, and Chat takes no turn times from Codex's legacy
  rollouts, whose turns fold under "Details". Claude Code's own `durationMs` can be far
  shorter than a turn's wall time, so "Worked for" can read longer than the
  program's figure.
- In Grok Build, earlier history loads by itself at most 4 MiB a request.
  Inside a longer turn, or at a line longer than 2 MiB, it waits for Load
  Earlier Messages, and the loaded part of that turn folds under the time its
  end record gives, or "Details" without one. The other programs' lists keep
  loading by themselves as Load Earlier Messages does.
- Conversation text now rests on the device, in the protected cache that
  [PRIVACY.md](../../PRIVACY.md) describes.
- Not in this version:
  - Chat on native Windows Hosts, and keyboard operation of cards and menus.
  - Oh My Pi's multi-select questions, option notes and typed answers, a
    one-form answer to several questions, and steering a running Oh My Pi
    turn from Chat. Pi's extension dialogs, and Oh My Pi skills in a
    project's ancestor directories.
  - Grok Build's Background Work, a Stop on the terminal's Composer for
    Grok Build, its questions beyond one single-choice question (several
    questions, multi-select, a typed answer) and skipping one, Keep Running
    on its subagent stop panel, and its minimal mode, where Chat holds every
    message and Stop presses nothing. Skills named like a Grok Build
    built-in command, which Grok Build offers only as `/local:<name>` or
    `/user:<name>`.
  - For OpenCode: its skills and server and custom commands in the `/` menu;
    paths and images sent as attachments; steering a running turn from Chat,
    or starting a conversation from OpenCode's home screen; several
    questions, multi-select questions and typed answers, and a rejection
    with feedback; subagent progress and Background Work; a terminal
    Composer Stop that presses the second Esc; and, as ADR 0025 records,
    stores other than the default one and tool output OpenCode moved to a
    file of its own.
  - The segment before a Codex undo. After one, Chat shows only the turns
    written since; the reducer accepts the earlier segment, but nothing loads
    it yet.
  - Claude Code's session registry (`~/.claude/sessions/<pid>.json`) as a
    second Blocked signal. Cards follow herdr's Blocked, and an open
    AskUserQuestion call for the question pages herdr reports idle.
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
    SendMessage, which stays listed as finished while it runs again and
    takes its next end's counts when that arrives.
