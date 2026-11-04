---
status: accepted
---

# Chat reads OpenCode's session store through a bounded Host query

OpenCode 2.x keeps every conversation in one SQLite database in WAL mode,
`opencode.db` under `~/.local/share/opencode`, and writes no transcript file.
ADR 0024 builds Chat on the Transcript: Heeler reads the file the Agent's
program writes, read-only over SFTP, and runs nothing on the Host for it. An
OpenCode Agent has no such file, and copying the database over SFTP to read it
in the app would mean reassembling pages that OpenCode rewrites while the copy
runs (see Alternatives). The store's tables and rows, and the OpenCode and
herdr behaviour Chat relies on, are recorded in
[OpenCode's session store](../research/opencode-session-store.md) for OpenCode
2.0.32 and herdr 0.9.5.

## Decision

For an OpenCode Agent, Chat reads the conversation herdr reports from
OpenCode's own database with one short, read-only query on the Host per poll,
through the `sqlite3` or `python3` the Host already has. This replaces ADR
0024's SFTP reads for OpenCode only. The rest of ADR 0024 holds: nothing is
installed on the Host; herdr is unchanged and still owns the Agent's identity,
Agent Status, `agent.prompt` and `agent.send_keys`; the Composer, Blocked
Cards and the cache work as described there.

### The query

- Each query is one exec of a fixed POSIX script, bounded as the Changes
  view's git scripts are: output between nonce markers, a remote watchdog
  that kills the exec's process group, an ordinary-session channel, and an
  exec that is never cancelled once dispatched, so the script's own exit
  frees its channel.
- The reader is `sqlite3` (on macOS, `/usr/bin/sqlite3` first), else
  `python3 -I`. macOS's `/usr/bin/python3` is never used: without the Command
  Line Tools it is only a prompt to install them. With neither reader, or
  only a `python3` built without its `sqlite3` module, Chat says the Host
  needs one.
- The CLI runs with `-init /dev/null -readonly -batch -bail -noheader -list`
  and a one-second busy timeout; `-init /dev/null` keeps a user's
  `~/.sqliterc` from adding output or writing a file. Python opens a `mode=ro`
  URI with the same timeout. Both set `PRAGMA query_only = 1` and read inside
  one transaction, so every statement sees one snapshot.
- The SQL is fixed text from the app, carried once in a quoted
  here-document whose delimiter holds the nonce, and whichever reader runs
  reads it: Python's program is fixed text passed with `-c`, and it splits
  the statements where the CLI does. The SQL interpolates only integers and
  the validated session id; no text from the Host or the user. Every
  reader's output passes through `head -c` with a 2 MiB cap.

### What it reads

- Only OpenCode's default store: `opencode/opencode.db` under
  `$XDG_DATA_HOME` when the exec's environment sets it to an absolute path,
  else under `~/.local/share`. A database named by `OPENCODE_DB` or a channel
  build's `opencode-<channel>.db` is not read, because the exec cannot see the
  environment the OpenCode process started with. When the session is not in
  the default store, Chat names the other `opencode-*.db` files beside it, and
  never reads them.
- Only the tables `session_v2`, `session_message`, `event_sequence` and
  `session_inbox`, the `pragma_table_info` of those four, and table names from
  `sqlite_master`. Every row read is filtered on the one session id herdr
  reports: `ses_` followed by 12 hexadecimal digits and 14 letters or digits,
  checked before the id reaches a query. A session with a parent belongs to a
  subagent and is not shown; Chat follows the root session herdr reports.
- Rows are slimmed in SQL before they leave the Host: provider state,
  snapshots, diagnostics, previews, before and after copies of files, and
  full revert patches are dropped. Text and reasoning keep 64 Ki characters,
  tool output 16 Ki (256 Ki when a row is expanded), patches 64 Ki, a prompt
  256 Ki, and the queue of waiting prompts 16 items of 16 Ki each. A row still
  over 1 MiB arrives without its content.
- Reads are budgeted: the newest 512 KiB of rows when a conversation opens, at
  most 1 MiB per poll (more reads the tail again), and older pages from
  512 KiB up to 1 MiB, at most 8 MiB per search. A read's lines run past its
  rows' data, and it ends with the row that crosses its budget, so every
  budget stays at half the 2 MiB cap or less. Output cut at the cap halves
  the budget, at most twice; then the conversation is reported as too large
  to read in one query.
- Sessions OpenCode imported from 1.x are read in `session_v2` like any
  other. They keep their 1.x `version` and have no `idle` rows, and 1.x took
  no steers, so until an `idle` row shows such a session going on in
  OpenCode 2, each prompt opens a turn and the turn before it ends with its
  last step.

### Polling and changes

- While Chat shows an OpenCode conversation, it polls every 2 seconds where
  ADR 0024 reads every second (the Agent Working or Blocked, and for 15
  seconds after a change, a send or a status change), and every 4 seconds
  otherwise.
- `event_sequence.seq` for the session moves in the same transaction as every
  row change. A poll that finds the counter unchanged prints only the reader's
  version, the counter, whether the side files exist and the reader's exit
  status: about 110 bytes with the markers. Otherwise the poll reads the rows
  newer than the newest held, the rows still open (an unfinished step, a
  running compaction or shell command), rows updated within 2 seconds of the
  newest update seen, the session row and the queue. Either way it uploads
  its whole script, about 14 KiB, which a test keeps under 16 KiB: the
  statements travel once, and the poll slims its rows once, marking a row
  past its budget in the same pass.
- OpenCode rewrites its newest assistant row while a step runs, and a revert
  commit deletes rows while the counter and the highest `seq` keep rising.
  Each poll therefore also counts the rows in the window Chat holds, and a
  different count resets the conversation from a fresh read of the tail.
  Because a revert can delete saved rows, a live OpenCode window never joins
  saved history above it; earlier rows come from the store again, and a saved
  conversation still shows until the first read.

### Failing closed

The query shows nothing it cannot account for:

- a store with only OpenCode 1.x tables (`session`, `message`, `part`) reads
  as an older OpenCode, which Chat does not read;
- a table or column the statements name that the store lacks reads as an
  unsupported layout, naming what is missing;
- a session id absent from `session_v2` reads as not found;
- a `session_v2.version` whose major version is above 2 reads as an
  unsupported format;
- the statements use only the syntax of SQLite 3.25 with JSON1 (window
  functions, the JSON1 functions, `pragma_table_info` as a table-valued
  function), which a test checks. They also nest shallowly enough for the
  fixed 100-entry parser stack of SQLite before 3.46, with 20 entries to
  spare, which a test checks where its SQLite can cap that stack. iOS 26's
  SQLite, which CI tests on, cannot, so the same test also keeps every
  statement's parentheses and expressions from nesting deeper than the
  deepest do now. A reader that reports an older SQLite, or fails on that
  syntax, on JSON1 or on its parser stack, reads as too old.

### What it never does

- It never writes, migrates or attaches a database, never reads OpenCode's
  settings or credentials (`service.json`, `auth.json`, its config files, the
  `credential` table), and never runs `opencode`: its CLI may start or
  replace OpenCode's background service, and every OpenCode process that
  opens the database migrates it.
- The only Host effect is read marks in an existing `-shm`. Heeler never
  opens with `immutable=1` or read-write, and never starts a reader while the
  store's `-wal` or `-shm` file is absent, as both are on Linux once
  OpenCode's last connection has closed: such a store reads as closed. A
  read-only open of it fails with Apple's SQLite, but stock SQLite (3.22 and
  later) creates both files to open it. A store that closes between the check
  and the open can still be left with both files, which SQLite reuses on the
  next open. Chat then keeps the saved messages, says the database is closed,
  and checks again. `immutable=1` would open such a file, but it assumes no
  writer: if OpenCode starts writing mid-read, the reader can return torn
  pages.

### One query at a time

- Chat runs at most one OpenCode query per Host connection at a time, and a
  query keeps its turn until its exec has ended on the Host, not merely until
  Chat stopped waiting.
- The remote watchdog ends the script after 8 seconds, inside Chat's
  10-second deadline. A query that passes the deadline anyway, on a slow
  link, fails as a timed-out read without reconnecting and keeps its channel
  until the watchdog has ended it; a query waiting behind it times out
  without opening a channel.
- Each consecutive timeout doubles the poll interval, up to 30 seconds, until
  a read succeeds.
- The Console does not prefetch OpenCode conversations after a connect or a
  status change, as it does transcripts (ADR 0024): every status change of
  every OpenCode Agent would cost an exec while nobody looks.

## Sending while OpenCode works

herdr's `agent.prompt` refuses a Blocked Agent only while it validates the
request. It then pastes the text and writes Enter 300 ms later, whatever the
screen shows by then (in herdr 0.9.5,
`src/app/api/agents.rs:13, 168-177, 260-266` and `src/pty/actor.rs:117-153`).
A permission or question that OpenCode raises inside that window replaces its
prompt and takes the Enter: Allow once for a permission, the first option for
a question. Nothing tells the user.

The store cannot narrow the window. OpenCode marks a tool call running, with
its `time.ran` stamp, when it publishes the call, before the tool asks for
permission during its execution, and a pending request lives only in
OpenCode's memory. No row tells a tool about to ask from one already running.

Chat therefore holds a message while OpenCode works, as it does for Oh My Pi:
while the screen shows a running turn, Chat sends nothing and says "OpenCode
is working. Send once it's idle, or steer from the terminal." A steer from
Chat would also outlive Stop, because OpenCode's interrupt resumes with a
steer still waiting. What remains is a background subagent that asks for
permission while the root session is idle, inside the same 300 ms.

## Identity

Chat follows only the `ses_` id herdr's OpenCode integration reports, and
that report goes stale. After `/new` or `/clear`, OpenCode shows its home
screen, where the integration reports nothing, so herdr keeps the old id and
its Done status until the first prompt of the new session.

- **The start-screen watch.** Each time Chat re-reads an idle OpenCode
  Agent's record (at least 5 seconds apart, as in ADR 0024), it compares the
  terminal title with the followed session's exact title, and on any other
  title reads the screen once. OpenCode's home screen there marks the report
  stale: Chat shows no conversation and says OpenCode has left it, until
  herdr reports another session, the screen shows a session again under the
  stale session's own title, or Retry finds a session on screen. After
  `/new` Chat says so at the next idle recheck, within about 10 seconds (1.0
  to 7.3 s in three samples). Until then a send is still held, by the screen
  read before each send (ADR 0024), which finds OpenCode's home
  screen; the confirmation below lets it through, since the title
  `OpenCode` says nothing, and Chat says OpenCode has left the
  conversation only at that recheck. The Console's record counts only when
  it changes: a session picked in OpenCode's terminal while herdr reports it
  idle changes no status, so no snapshot follows, and that record can name
  the session before it. The title alone cannot decide: OpenCode titles its
  home screen, an untitled session and a session with a fallback title all
  `OpenCode`, and sets no title at all while its title setting is off.
- **The confirmation before each send.** Before every send, Chat reads the
  Agent's record again and compares the terminal title with the session's
  title. It refuses the send, and says why, when herdr now reports another
  session (Chat then switches to it), when the session is stale, when the
  title shows another conversation, or when it cannot check. This narrows,
  but cannot close, the gap until herdr pastes: a session switched in the
  terminal within that round trip still receives the message.

## Alternatives

- **An in-app SQLite reader over SFTP.** It keeps ADR 0024's SFTP-only
  reads, but committed data can sit in the WAL, whose frames would need
  validating, and checkpoints rewrite database pages while a copy runs.
- **`immutable=1`.** Torn pages when OpenCode writes mid-read, and it opens a
  store that Chat reports as closed.
- **A read-write open.** It creates side files and may checkpoint on close,
  which writes the database.
- **OpenCode's CLI** (`opencode session export`, `opencode api`). It may start
  or replace the background service, migrates the database, and exports whole
  sessions.
- **OpenCode's HTTP server.** The only source of streaming text, but it needs
  the password in OpenCode's `service.json`: Heeler would read a credential
  and forward a port.
- **`sqlite3 -json`.** It encodes `data` twice, prints nothing at all for an
  empty result, and needs SQLite 3.33.
- **Decoding JSON in Python.** A second slimming implementation; one SQL text
  serves both readers.
- **Reading OpenCode 1.x tables.** Sessions imported from 1.x live in
  `session_v2` and are read there; a store never imported is not read.
- **A long-lived reader process.** It would hold a connection to the user's
  database between polls and need a lifecycle of its own. If polling proves
  costly, the pace goes down instead.
- **A per-Host gate in the Console.** It is released when the Transport call
  returns, while the exec that call started may still be running.
- **Reporting `/new` from a Heeler plugin or a patched integration.** Chat
  works with herdr's OpenCode integration as it ships.
- **Inferring the terminal's session from the store** (`session_v2.time_viewed`
  or OpenCode's `kv` state). A guess about what the terminal shows.
- **Trusting herdr's Done after `/new`.** herdr keeps the old id, and the next
  message would start a new session.

## Consequences

- Following an OpenCode conversation costs one exec channel per poll on the
  Host's connection, where other programs cost SFTP requests. That exec
  shares the connection's four ordinary-session channels with Changes, the
  Skills probe and Agent discovery, and uploads its 14 KiB script each time:
  up to about 26 MB an hour at the 2-second pace and half that at the
  4-second one. Through a loopback `sshd` on the development Mac, a query
  took p50 49 to 51 ms on the Host and about 13 ms more CPU in its children
  than a trivial exec (15 ms counting its own processes); with Chat showing
  for 425 seconds, the queries used 0.49% of one core, 0.94% counting each
  exec's own processes
  ([Costs](../research/opencode-session-store.md#costs)). The round trip
  Chat sees for a query, over loopback or a slower link, is not yet
  measured; if it is high, the polling pace goes down.
- The Host needs `sqlite3` with JSON support from SQLite 3.25 on, or
  `python3` 3.6 or newer whose SQLite is that recent. macOS has
  `/usr/bin/sqlite3`; many Linux server images have `python3` but not the
  `sqlite3` CLI. Without either, Chat explains and the terminal stays
  available.
- The schema is OpenCode's private format and changes often. Missing tables
  and columns, 1.x-only stores and newer session versions fail closed with an
  explanation. A change inside a row's JSON cannot be caught that way: unknown
  row and item types are counted and skipped and unknown fields ignored, so a
  change hides content until the adapter learns it. No allowlist of
  OpenCode's migrations is kept, because every release adds some and an
  allowlist would refuse every upgrade.
- The database holds every project's conversations. Chat's statements name
  only the four tables and the one session id herdr reports, and
  [PRIVACY.md](../../PRIVACY.md) says so.
- The store lags the screen: OpenCode writes a step's assistant row at the
  provider's first output and a text block when it ends, so a turn can show
  only its prompt for many seconds. Chat shows progress from Agent Status, not
  streaming text.
- A store other than the default one, an `XDG_DATA_HOME` set only in
  interactive shells, and an OpenCode server on another machine read as a
  missing database or Conversation Not Found, naming the other stores Chat
  found.
- Tool output OpenCode moved to a file of its own is not read; the row says
  the full output stays on the Host.
- Native Windows Hosts stay without Chat (ADR 0024).
