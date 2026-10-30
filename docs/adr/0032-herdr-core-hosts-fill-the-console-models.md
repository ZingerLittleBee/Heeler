---
status: proposed
---

# herdr-core Hosts fill the Console's Herdr TUI-shaped models

herdr-core Hosts (ADR 0031) have flat Terminals with labels, parents, and a
self-reported Program Status, and no workspaces, tabs, or plugins of their
own. The Herdr desktop app, when it runs on a core, keeps its spaces, tabs and
panes in the core document `herdr-app` and labels its Terminals
`herdr.space` and `herdr.tab`. Herdr TUI support stays as it is, and every
Server Kind is presented with Herdr TUI's Workspaces, Tabs, and Panes.

## Decision

- herdr-core gets its own Transport, codec, and projection. The projection
  fills the Console models Herdr TUI already fills (`Agent`, `ConsoleAgent`,
  `ConsoleTerminal` and its `PaneInfo`-shaped values) instead of neutral
  replacements. herdr-core never goes through the Herdr TUI `Transport`
  protocol.
- The Console lists the Terminals of the Host's own core only, never those of
  machines that core reaches.
- Every Terminal lands in a Workspace and a Tab. A Terminal labeled into a
  desktop space shows in that space and tab, under the names and order the
  desktop app shows. A space that exists only in labels, with no desktop
  document naming it, is named after its first Terminal's checkout folder, as
  the desktop app names a space it has not been given a name for. Any other
  Terminal joins a derived Workspace of the Terminals launched in its
  directory, as its own Tab. An unlabeled Terminal started from inside
  another, such as a subagent, joins that Terminal's Workspace and Tab as
  another Pane.
- Heeler keeps no organization of its own. Workspaces it creates, and Tabs it
  adds to a desktop space, carry the desktop app's labels, the adoption
  contract herdr-app documents, so a desktop app on that core shows them too.
  A Terminal opened in a derived Workspace stays unlabeled, so it never
  appears in the desktop app uninvited. Heeler never writes the `herdr-app`
  document, which is that app's private model: the core refuses a write
  against a stale version, and the desktop app answers that conflict by
  replacing its own layout with the stored document, so a Heeler write would
  rearrange the desktop user's window.
- Renaming goes through the desktop app. A Workspace the desktop app shows can
  be renamed while that app runs on the Host: `herdr-app status` says whether
  it does, and `herdr-app do space.rename` with the space's id and the new
  name renames it, without automatic retry. A name typed for a new Workspace is
  applied the same way once the app has adopted it, and the field is hidden
  when the app cannot be reached. Derived Workspaces have no name to rename,
  and Rename Agent is not offered.
- A Terminal is an Agent while its foreground program is a known agent
  program, or a program that has reported a Program Status of its own. A
  Program Status counts only while it can be tied to the current foreground
  program: its `app` names that program, or it was reported after the
  foreground last changed. A shell or any other program in the foreground
  ends the Agent, whatever was reported last.
- Heeler starts an Agent the way the desktop app does: a kept Terminal whose
  argv is the user's shell running the agent and then staying,
  `$SHELL -ic '"$@"; exec "$0" -i' $SHELL <agent> ...`, or for fish
  `fish -ic 'command $argv[2..]; exec $argv[1] -i' fish <agent> ...`, or on
  Windows PowerShell's `-NoExit -Command "& '<agent>' ..."`. The interactive
  shell supplies the user's own PATH and variables, and the Pane returns to
  that shell when the Agent exits, as on Herdr TUI. The launch request adds no
  PATH of its own. A Template is launched by name, as the core runs it, without
  the wrapper or the session flags of ADR 0034.
- Worktrees follow the desktop app's convention: `git worktree add -b
  worktree/<name> ~/.herdr/worktrees/<repository>/<name> HEAD` in the
  Checkout, then a labeled new Workspace there. Removing one ends that
  Workspace's Terminals, then runs `git worktree remove`, keeping the branch.
- Native Windows herdr-core Hosts get the same Console, with these
  differences. Staged Images and Files are written by the core's
  `terminal.put` into its state directory beside the Terminal, which the core
  removes with the Terminal; this amends ADR 0018's refusal of uploads for
  herdr-core Hosts only, since no SFTP mode bits are involved. New Workspace
  is offered. Rename and Worktrees stay off until each passes a test on a
  Windows Host.

## Why

The desktop app's wrapper shell outlives the agent, and the core keeps the
agent's last Program Status while the Terminal runs on, so a reported status
alone keeps an exited Agent, or the program that replaced it, looking like the
Agent that left. Launching through the user's interactive shell matches the
desktop app, which a Terminal Heeler starts may end up shown in, and avoids
copying the SSH session's PATH over a core that the desktop app started with
the user's login PATH.

## Evidence

Source-reviewed against herdr-core v0.1.13 (`88fe4e7`) and the Herdr desktop
app v0.1.9 (`3e32d75`). This is source evidence, not runtime acceptance from
the app.

- [defaults/AGENTS.md](https://github.com/herdrdev/herdr-app/blob/v0.1.9/defaults/AGENTS.md#L131-L139)
  and [src/SKILL.md](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/SKILL.md#L63-L66)
  document the adoption contract: `herdr.space` shows a Terminal in that
  space, `herdr.tab` picks its tab or the app creates one, adoption turns on
  keep, and unlabeled Terminals stay hidden.
- [api/doc.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api/doc.rs#L9-L38)
  refuses a `doc.set` whose version is not current;
  [window.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/window.rs#L1756)
  treats that conflict as a replace of the app's own layout.
- [control.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/control.rs#L90-L96)
  maps `herdr-app status` and `herdr-app do <command> <args>` onto its
  control socket;
  [commands.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/commands.rs#L35)
  defines `space.rename` with an id and a name, and
  [model.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/model.rs#L232-L242)
  names an unnamed space after its first Terminal's checkout folder.
- [window.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/window.rs#L110-L119)
  builds the POSIX and fish wrappers, and
  [programs.rs](https://github.com/herdrdev/herdr-app/blob/v0.1.9/src/programs.rs#L268-L287)
  recognizes those and the PowerShell form.
- [mods/worktree/main.js](https://github.com/herdrdev/herdr-app/blob/v0.1.9/defaults/mods/worktree/main.js#L15-L16)
  places checkouts under `~/.herdr/worktrees/<repository>/<branch>`.
- [api/run.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/api/run.rs#L6-L11)
  runs a Template when `terminal.run`'s first argument names one.
- [put.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/put.rs#L5-L6)
  caps one `terminal.put` at 8 MiB and
  [writes it](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/put.rs#L36-L67)
  under `<state>/files/<address>/`, which
  [runtime.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/runtime.rs#L647)
  removes with the Terminal.

## Considered options

- Neutral models first, then both projections. Cleaner, but it rewrites the
  Herdr TUI side, whose support stays as it is.
- A separate Console for herdr-core Hosts. It keeps two lists and two details
  apart for good, while Pins, the Host filter, banners, and Live Activities
  already gather Agents across Hosts.
- Heeler's own organization stored in the core. It would allow renames on
  headless cores, but a core that also serves the desktop app would then show
  two organizations of the same Terminals.
- Grouping every Terminal by its launch directory, ignoring the desktop app's
  labels (PR #538). Simple, but a desktop user would see a different
  organization on the phone than on the desktop.
- Running the agent's executable directly, with the PATH an SSH probe found
  (PR #538). It needs no shell, but the Pane ends with the Agent, and the
  agent misses what only the user's shell rc sets.

## Consequences

- herdr's generated `PaneInfo` becomes a model both projections fill;
  regenerating herdr's wire types can require a matching change in Heeler's
  herdr-core projection.
- Agent Status gains Error, which only herdr-core reports.
- Actions only Herdr TUI can serve are offered by Server Kind, not attempted
  and failed.
- Derived Workspaces exist only in the app's view and change as Terminals come
  and go. A kept Terminal that restarts takes its last directory as its new
  launch directory, so the device remembers the directory it first saw a
  Terminal launched in and keeps it in the same derived Workspace.
- Recognizing an Agent needs both wrapper forms, interpreters running an
  agent's script, and a table mapping reported `app` names to Heeler's agent
  kinds.
- A kept Terminal between losing its program and restarting has no foreground;
  it shows as restarting and is no Agent.
- Renaming over SSH depends on `herdr-app do` reaching the desktop app's
  socket from an SSH session (unverified).
- On Windows a Staged Image or File larger than 8 MiB is refused before it is
  sent. The files sit under the user's profile with whatever access it grants;
  the core does not narrow it (unverified).
