---
status: proposed
---

# herdr-core Hosts run a Heeler Host Helper and its harness extensions

On Herdr TUI the Heeler plugin runs inside herdr: its hooks send Agent
Notifications and Live Activity updates through the Push Relay while the app is
away, and it collects Usage on the Host (ADRs 0027 and 0028). herdr-core runs
no plugins and sends nothing to anyone. Its status and turn events reach only
clients connected to its socket. Its only other signal is a note: a marked
line the core types into a parent agent's Terminal when a child Terminal that
agent started gets stuck or exits
([notes.rs](https://github.com/herdrdev/herdr-core/blob/v0.1.13/crates/herdr-core/src/notes.rs#L165-L177)),
which reaches that agent and nobody else. Chat also needs every displayed
herdr-core Agent's session (ADR 0034), and Pi has no record of its session
that Heeler can read from outside the process.

## Decision

- macOS and Linux herdr-core Hosts run the Host Helper: Heeler's own
  background service, built from the plugin's sources, bundled with the app,
  copied over SFTP into a directory Heeler owns, and registered as a user
  service (a LaunchAgent on macOS, a systemd user unit on Linux). The app
  replaces it only with a newer version, or when it is missing or damaged,
  never over a newer one another device installed, as ADR 0027 does for the
  plugin. It runs on the Node.js the Host already has, found as for the
  plugin and named by its absolute path in the service, since a systemd user
  unit's `PATH` holds only system directories. That path is a manager's own
  stable link where the search finds one (fnm's default alias, nvs's default,
  nodebrew's `current`, n's and pnpm's directories, Homebrew's and the other
  system directories), else the binary itself, and never a binary outside a
  Node.js install's `bin`, such as another program's private runtime. The service restarts whenever
  it stops, not only on failure. A user service does not start with the
  core's environment, so for Usage the Helper reads the variables that locate
  Accounts, such as `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, from the core
  process's environment, only those by name, at the pid `server.status`
  reports. The record stays per session, `sessions/<session>/runtime.json`,
  so two cores on one account keep their own Default Account, and each
  reconnect reads it again.
- On Linux the Helper needs systemd linger, as the core does, to run while
  nobody is logged in. The install screen checks it and offers to turn it on.
- On macOS the Helper's LaunchAgent has `LimitLoadToSessionType` set to
  `Background` and is bootstrapped into `user/<uid>`, the only domain a plain
  SSH exec could use both with and without a desktop login. `gui/<uid>` refuses
  a bootstrap while nobody is logged in and loses its agents at logout, and
  `user/<uid>` refuses a property list without that key. `[Aqua, Background]`
  is accepted there as well, but a desktop login also loads that list from
  `~/Library/LaunchAgents` into `gui/<uid>`, where the agent stops at logout,
  and while `gui/<uid>` holds the label a bootstrap into `user/<uid>` fails. In
  `user/<uid>` the agent outlives the SSH session and a desktop logout, and
  restarts when killed. The evidence comes from a throwaway Tart VM of macOS
  26.5, not a Mac anyone uses (herdr compatibility, launchd bootstrap domains).
  On the owner's Mac, macOS 27.0.1, the app's install of Helper 0.5.3 over SSH
  bootstrapped it into `user/501` with `LimitLoadToSessionType` `Background` and
  the absolute Node.js path, `gui/501` answered 113 for its label before and just
  after the install, launchd started it again with
  a new pid after `kill -9`, and its removal left `launchctl print` answering 113
  and the listed folders as they were before the install (herdr compatibility,
  the Host Helper's LaunchAgent on a real Mac). The list is `~/Library/LaunchAgents/dev.bybee.heeler.host-helper.plist`, its
  label is in the install record, the Helper directory is
  `~/Library/Application Support/heeler/host-helper`, whatever `XDG_DATA_HOME` an
  SSH login has, and the agent logs to `helper.log` there. An install writes that
  log empty, so it starts private and grows until the next install or removal,
  since nothing on a Mac rotates it as the journal does on Linux.
- The login Keychain is out of reach from that domain, with the desktop logged
  in and unlocked or with nobody logged in, as it is from a plain SSH exec. A
  read of Claude Code's Usage Limits there answers `keychainUnavailable`, so
  Usage names that reading as the one that needs the user's own login, as the
  plugin does over SSH, in words that fit a core Host. This comes from the same
  VM with a dummy credential, compared by equality with what `security` and
  Claude Code returned: `gui/<uid>` reached the dummy and sent it as a bearer to
  a local stub, `user/<uid>` did neither, and no real Usage Limits value was
  read (herdr compatibility, the login Keychain from a LaunchAgent). On the
  owner's Mac, macOS 27.0.1 with Claude Code 2.1.316 signed in, the read answered
  `keychainUnavailable` and Usage showed that wording while Token Usage kept
  counting. That read ran from the app's SSH exec, not from the LaunchAgent, so
  whether the agent itself reaches the login Keychain on a real Mac is untested
  (herdr compatibility, Claude Code's Usage Limits on a real Mac).
- The Helper connects to the core's socket directly, never through `hc`, so it
  never starts a core. While no core runs it waits for one. It finds the
  socket as the app does (ADR 0031): the session's `core.lock`, else the
  session's default socket path, because `core.lock` appears only once a core
  has started for that session. On each connection it asks `server.status`
  for the core's pid before it subscribes, and it rebuilds its inventory from
  the subscription's snapshot, since event numbers restart with every core
  process.
- It subscribes to status and turn events and sends Agent Notifications for
  Blocked, Error and Done, and Live Activity updates, through the Push Relay,
  to the devices whose Notification Registrations it holds, encrypted with
  their Notification Keys. It serves Usage reads as the plugin does: the app
  runs the Helper's `usage-query.js` by the Node.js the session's record names,
  or by the service's when the record's cannot run, in one bounded exec, and
  the query and worker are the plugin's own modules.
  The app's Usage read makes the session's folder, and the Helper also follows
  a session with a folder, since Usage needs a core's environment without any
  notification registration. A session nobody registered or read stays
  untouched. Those Notification Registrations live in the Helper's own directory, one entry
  per device for the core session the Host targets, never in the plugin's
  registration file.
- The Helper decides what to send from each Terminal's state after a debounce,
  not from the event at hand, and keeps what it last notified in
  `state/notify/<session>.json`, so a restart or a dropped connection loses
  nothing and a failed send is tried at the next decision. A quiet Terminal has
  no event to bring that decision, so a send that leaves devices unsent arms one
  by itself, for those devices alone and from the state then: five waits in
  memory from 30 seconds, doubling to a ceiling of five minutes, kept apart from
  the debounce. A send that reaches everyone or a state change starts them over,
  and a connection's end clears them. After the fifth, only the next decision
  tries again, so a relay that stays down costs a bounded number of sends and a
  notification can still be lost. A core seen for the
  first time sets that memory without sending, so an install or a new core id
  announces nothing that already happened. The memory goes when a session's
  connection ends with no registration naming it. Error is sent under the
  Blocked trigger, in its own word.
- In-app banners and Live Activity on a core Host are gated on this device's
  confirmed registration, and an activity also on a Helper that can drive it:
  one that runs, at 0.5.0 or newer. The app starts the activity and writes its
  push token into this device's entry in the Helper's directory. While the
  registration is still being read the app neither starts an activity nor ends
  one it holds, so a launch does not lose a running activity. After a debounce,
  the Helper compares what each token should now show with what it last sent,
  kept in `state/activity/<session>.json`, and sends an update or the end
  through the Push Relay. Each token has its own content, since Done is per
  device. Unlike a notification, a core seen for the first time does send: an
  activity shows what is true now, whereas a notification announces a change.
  Error counts and reads as Blocked there, so the Push Relay and the widget do
  not change. An update is built from the Terminal's record, so its workspace is
  the folder name, never a desktop app's space name, and a configured Tab or Pane
  field stays empty until the app next updates the activity itself.
- A turn's end comes from the status word, as in the app: an Agent ends a
  turn when it goes from Working to Done, and, unless it is known to report
  done, also when it goes from Working to Idle. Claude Code, Codex, Pi, Oh
  My Pi and Grok Build (1.0.70, signed in) are known to, as is any Terminal
  that has reported done since its last restart. Turn events cannot tell it:
  the turn count also moves when an Agent enters Blocked or Error, or when
  Codex passes through Working as it starts, and a move from Blocked straight
  to Done brings no turn event.
- Done is per device there as in the app. When the app opens an Agent, or
  has one open as it ends a turn, it writes a small seen mark (device, core
  id, Terminal address, turn, status word) into the Helper's directory over
  SFTP. The Helper counts an Agent as Done for a device when it ended a turn
  after that device's last mark and still reports idle or done, in
  notifications and Live Activity updates alike. A device's marks go with its
  registration, and all of them with the Helper. The app keeps its own marks in
  the device's Host memory, beside the core id, and they go with that memory.
  The file is `seen-<Notification Key id>.json`, never named from a Terminal
  address, and holds all of that device's marks on the Host, so each change
  costs one exec to find the directory and one SFTP write, and a failed write
  is carried by the next. `plugin/test-vectors/herdr-core-seen-mark-v1.json`
  pins it. A later turn count covers a turn; at the same count the same word
  does, and idle and done cover each other, while a mark taken in Blocked, Error
  or Working does not cover the Done that follows. When another Host of the same
  session takes over a device's entry, that entry's old file stays until the
  Helper is removed.
- A subscribe snapshot stands in for what happened since the last report known,
  as event numbers cannot be resumed. Only leaving Working moves the count, so
  at the same count the words are compared as live. At a moved count, or at
  first sight with a count above zero, a report of done ended a turn, and so
  does idle unless the program is known to report done. An idle that left
  Blocked while nobody was connected can therefore read as a finished turn once
  the count has moved, which errs towards one extra Done.
- With the Helper come Heeler's extensions for Pi and Oh My Pi, placed in the
  folders those programs load extensions from on their own
  (`~/.pi/agent/extensions`, and `~/.omp/agent/extensions` for each Oh My Pi
  profile). No configuration file changes. An extension does nothing outside
  a herdr-core Terminal (no `HC_TERMINAL_ID`); inside one it reports its
  session as a `heeler.*` label on its own Terminal, through one JSON-RPC line
  to `$HC_TERMINAL_SOCKET`, and Pi's also reports Program Status for Pi
  releases before 1.1.0. The label is `heeler.session`, a JSON object with
  `session`, `file` when the session has one, `pid`, and `start` as the app's
  process reader reads it where the platform has one. Only the program holding
  the Terminal writes it, never a subagent or a headless run a tool started.
  The extension runs inside those programs, and the Helper's own process
  loads no extension. The long-running service starts only `/bin/ps`, for the
  environment read and a Usage lock's owner on macOS, and the query and worker
  only what the session's record locates, so none of them can start a core.
  The extension's one child is `/bin/ps`, reading its `start` on macOS, which
  has no `/proc`.
  Pi and Oh My Pi get the same file, `heeler-session.js`: Pi's version resolves
  only under Pi, so the status part stays silent under Oh My Pi. The profiles
  are read on the Host by the Helper's own `extension-folders.js`, which the
  app runs through the Host's Node.js by its text, since an install's file list
  comes before the Helper is there. The install screen lists every file.
  Removing the Helper removes them, its service and its directory, and any
  folder the install created that is then empty. Both folders are made whether
  or not the program is on the Host yet, so a later install of either works. A
  profile made after the install is offered a repair, and until then it has no
  extension.
- A harness configuration file changes only when the user accepts that one
  change, shown exactly, and every such change can be undone. There are two:
  - OpenCode, offered from Chat when an OpenCode Agent's session cannot be
    bound. OpenCode loads a TUI plugin only from its plugin list, so Heeler
    copies its OpenCode plugin into a folder of its own under OpenCode's
    config directory and adds that folder to the list (`plugin` in
    `tui.json(c)`, or `plugins` in `cli.json`, by OpenCode's release, and
    refused for a version it can't place). The release is the one the Agent
    runs: its program asked for its version with the Agent's own PATH and
    directory, since the login shell's PATH can find another release, and a
    list in that release's file does nothing. Undoing removes the entry, then the
    folder; removing the Helper undoes it. The entry is one line, first in the
    list, relative to the file: `./heeler-opencode`. The folder holds the
    plugin's three files, and goes in before the entry so the file never names
    a folder that isn't there. If the user changed the file since, undo takes
    out only the entry, against what it read then. The plugin ships in the
    Helper's bundle and manifest, so publishing the Heeler plugin never ships
    it, and an app update doesn't refresh a copy already placed. Two files can
    name the one folder, after applying again once OpenCode moved from 1.x to
    2.x, so the folder goes only with the last record that names it. On 1.x
    the sheet says before the user agrees that Chat still can't show the
    conversation, since Chat reads only 2.x's store (ADR 0025).

    Removal undoes it after the listed files and created folders and before
    the Helper's directory. A record of the edit lives on the device that made
    it, so a removal from another device leaves it, harmless without a core. A
    file that refuses the undo doesn't keep the Helper: the Helper goes, and
    the edit stays listed with its Undo. So does a conflict on a file in the
    folder, once the entry is already out. A failed connection stops the removal
    as any step's does. A running OpenCode 2.x makes a `cli.json` out of
    `tui.json` whenever it finds none: on hc-lab on 2026-11-03, with Host
    Helper 0.5.3's edits for OpenCode 2.2.2 and 1.19.5 applied and both
    releases running, 2.2.2 did so during the removal, after `cli.json` went
    and before `tui.json` did, and the new file named the deleted folder until
    it was deleted by hand ([herdr compatibility](../agents/herdr-compatibility.md)).
    So the removal undoes a `cli.json` edit last, when no `tui.json` of
    Heeler's names the folder any more, and whichever undo takes the folder
    first takes the entry out of every other `tui.json`, `tui.jsonc` and
    `cli.json` beside it, as an undo of a changed file does. That covers a
    `cli.json` OpenCode made after an Undo of the 2.x edit alone, which keeps
    the rest of what OpenCode wrote. A file written between that read and the
    folder's removal can still name it.
  - Grok Build, offered where a Grok Build Agent shows no status because its
    automatic check left Program Status off: `[ui.notifications]
    program_status = "on"` in its configuration. The value is a quoted string:
    a bare `on` is not TOML (herdr compatibility, Grok Build 1.0.70).

  Heeler never edits Claude Code's settings, Codex's hooks or their trusted
  hashes, or Grok Build's global hooks.
- Native Windows herdr-core Hosts get no Helper for now, so no background
  notifications, Live Activity pushes or Usage: Windows needs a user-service
  design of its own, and none has been tested there. The app writes the Pi and
  Oh My Pi extensions there itself, through the core's `file.write`, one file per
  folder: Pi's, Oh My Pi's and each profile's, found from the locator's home and one
  SFTP listing. It writes only when the user asks from Chat's cannot-tell, after a
  sheet names each folder, as an install lists its files, since these folders load
  for every session on the machine (#590). Node has no creation time of its own, so
  on Windows the extension's label takes its `start` from one hidden `powershell.exe`
  child reading `StartTime.ToFileTimeUtc()`, which the program does not wait on and
  which gives up after 5 seconds. It starts the system's copy by its full path under
  `SystemRoot`, since a bare name is looked for first in the Agent's project, and
  keeps the first answer for the process's life. A label with no `start` is never
  adopted, so on Windows none is sent, and the next session event tries again.

This amends ADR 0024's "nothing is installed on the Host", and ADR 0025's
rejection of a Heeler OpenCode plugin, for herdr-core Hosts only; Herdr TUI
Hosts are unchanged.

## Considered options

- No background features on herdr-core. Nothing installed, but Blocked and
  Done reach the user only while the app is open.
- Running the Helper as a kept herdr-core Terminal. No service to register,
  but a kept Terminal comes back as a shell, not as the Helper, and it would
  show in every client's terminal list.
- `gui/<uid>` for the LaunchAgent. In the VM it reached the login Keychain and
  loaded at a desktop login, but it could not be installed while nobody was
  logged in and its agent stopped at logout.
- `[Aqua, Background]` in `user/<uid>`. In the VM it behaved as `Background` did
  while loaded, but a desktop login then started a copy in `gui/<uid>` that
  stops at logout and blocks a bootstrap into `user/<uid>`.
- Asking for each extension separately. The two folders load files without
  configuration or trust prompts and are cleaned by deleting the files, so
  one listed install is enough.
- Done without seen marks: one Done notification per finished turn, and no
  Done in Live Activity. Nothing written on open, but the Live Activity would
  count differently from the app, or count Agents the user already opened.

## Consequences

- A Host without Node.js gets no Helper; the app says so where the user turns
  on notifications.
- Without linger, systemd stops the Helper and the core about ten seconds
  after the user's last login ends, so the Helper runs only while some login,
  Heeler's own included, is open. Debian 13 lets a user turn linger on
  without a password; other distributions can ask for an administrator.
- The app runs `systemctl --user` over SSH exec with `XDG_RUNTIME_DIR` set
  itself, since a Host without `pam_systemd` leaves it unset. Its health
  check reads the unit's state, result and restart count, because a Helper
  that keeps failing at start, for example after Node.js moved, ends up
  failed for good.
- The next three points are what the macOS 26.5 Tart VM did; neither macOS 27
  nor a real Mac has been tried.
- A restart of the VM loaded nothing into `user/<uid>`, even with the property
  list in `~/Library/LaunchAgents`: not at boot, not at the first SSH login, not
  after a desktop login. If a Mac does the same, then unlike under linger the
  Helper is down until the app next connects, finds the agent missing and
  bootstraps it again, and no notification goes out in between. The app does so
  without asking, as nothing new is written, where it reads the Helper: Host
  detail, and the registration read that runs as each Host's connection comes
  up, on a device with a push token. Only with the record, the property list and
  a Node.js all in place, so it never restarts a removed or broken Helper.
- launchd reported no failed state in the longest watch, about five minutes, and
  no single read decides health. A Helper that dies at start can read
  `state = running` for a moment. One killed by a signal, as a V8 heap limit or a
  segfault kills it, shows the signal and no last exit at all. Both the signal
  and a non-zero last exit stay after it recovers. So the health check reads
  twice, more than ten seconds apart, and calls the Helper running only when
  both say `state = running` with the same pid. That caught every loop tried
  that dies at start, and can miss a Helper that stays up longer than the gap
  before each death, which only growing counters show. A first read that finds
  no such run gets one more read, so a Helper that has just restarted is not
  called failed. Host detail takes these reads, about eleven seconds beside the
  core's own checks, which finish first and leave the Helper's row checking. The
  notification switch and its gates read once, and so can
  be wrong about a Helper between runs or caught mid-loop. A move of Node.js
  shows exit 78 and stops the run count; with someone logged in the agent came
  back alone once the path did, but with nobody logged in it was still down
  after almost five minutes, and `launchctl kickstart` blocked until the service
  was booted out. So a repair uses `bootout` then `bootstrap`, in a bounded exec.
- A process goes on running the code it loaded, so an install that replaces the
  Helper's files stops the service first, once the upload has passed its check
  and only if the service is loaded. If the install is cut short after that,
  launchd holding no agent loads the new code at the next read, and a stopped unit
  offers Repair. Otherwise the old process would run beside new files, and every
  later read would call it the new version with nothing to offer. The Helper is
  down from there until the service starts again. A removal boots the agent out
  and deletes its property list in one exec, so that a read on another connection
  cannot load it back with no record left to clean up after it.
- An install cut short with its link cannot clean up after itself. On hc-lab an
  SSH forward that dropped mid-upload left a staging folder holding a
  half-written `.tmp-` file, the install record and the empty extension folders
  it had made, until the next install. A first install that fails while its
  link holds now takes all of that back at once, since nothing outside the
  Helper directory is written before the Helper is in place. Otherwise the next
  check of the Host clears the staging and `.tmp-` files and, with no Helper in
  place, the record and the empty folders it names, but only once nothing of an
  install has changed for five minutes, so that another device's install still
  under way keeps its files. A record goes only while no file it names is on the
  Host and nothing else is in the Helper directory, so a removal can still find
  them.
- A Helper already running outlives the Node.js it started from, so neither
  service manager reports anything when an upgrade removes a versioned path, as
  Homebrew's and nvm's are, though a restart would fail and Usage, which runs the
  path the session's record names, cannot read. The probe therefore checks the
  path the service would start next: `program` in `launchctl print` on a Mac, and
  `ExecStart` in the unit it wrote on Linux. A path that cannot run reads as
  **Node.js Moved** with Repair. The Helper is not made to exit over this: it still
  sends notifications, and nothing else about it is wrong until it stops. Usage
  asks for the Repair only when the service's path has gone too. When only the
  record's has, as after a Repair or when the service's link now leads to
  another binary, Usage runs the query with the service's Node.js until a
  Helper started on that Node.js records it when it reaches the core: soon after
  a Repair, which restarts the Helper, and otherwise only after its next start,
  since a Helper still running on the removed binary records that binary again
  at each connection. The probe
  names a manager's stable link where it finds one, so an upgrade through that
  manager moves the service along at its next start rather than stranding it,
  though a default switched to a version too old can then fail that start,
  which reads as Service Failed. Shims are the exception: mise's, Volta's,
  asdf's, nodenv's and proto's pick a version from the shell's tools and
  directory, and asdf's and nodenv's need their tool on `PATH`, so the binary
  each runs is named and still moves with every upgrade. On the developer Mac
  (2026-11-08, #644) the LaunchAgent named cursor-agent's bundled
  `dist-package/node` in a versioned directory, which cursor-agent replaces on
  every update: mise's shim, which the probe tries first, runs that binary
  there, since mise's own Node.js was installed but not active. The probe now
  passes over a binary outside a Node.js install's `bin`, so a Host with only
  such a runtime reads Node.js Missing. Services
  installed before that change keep their path until the next Install, Update
  or Repair. The check has run against scripts and fake
  service managers, and on one Linux Host: on hc-lab on 2026-11-02 (Debian 13,
  systemd 257, Host Helper 0.5.3, Node.js v22.23.3), renaming the Node.js the
  unit names under a running Helper read **Node.js Moved** with Repair, and Usage
  asked for the Repair. It has not run on a Mac where Node.js went away.
- The VM showed a notification that `node` can run in the background and listed
  it under Login Items, with no mention of Heeler. What the list does when the
  user turns it off has not been tried.
- The Helper computes the default socket path from its own environment. A
  core started under another `XDG_STATE_HOME` keeps its `core.lock` where the
  Helper does not look and has another core id behind the same socket path,
  so seen marks written for the earlier core do not apply to it.
- Opening an Agent on a Host with the Helper costs one small SFTP write. A mark
  that fails to write leaves that Agent counted as Done in the next push.
- Pairing still requires Herdr TUI; herdr-core Hosts are added by hand.
- The extensions load in every Pi and Oh My Pi session on the Host and must
  stay inert outside herdr-core.
- `heeler.*` labels are not authenticated and outlive the process that wrote
  them, so the app treats them as hints to verify (ADR 0034).
- Heeler's OpenCode plugin needs a user configuration file edited, and only
  on the user's word.
