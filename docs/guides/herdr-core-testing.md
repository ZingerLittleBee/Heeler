# herdr-core lab checklist

Use this checklist to validate a herdr-core Host on a real Linux machine
(hc-lab). These are acceptance steps, not a record of a completed test. A
macOS fixture run is separate evidence; [the testing guide](../agents/testing.md)
covers the fixture and CI.

## Setup

- A Linux box the `instabox` CLI is signed in to, with herdr-core 0.1.13 installed
  at `~/.local/bin/herdr-core`, `python3`, and a systemd user manager with linger on.
- On the Mac, one Simulator you hold for the run and the Heeler repository at the
  candidate you are testing.
- Name the candidate and the box in your notes before you start.

## Safety rules

- **A unique `HC_SESSION` for everything you start.** The default session and any
  session you did not start are not yours. The scripted check generates its own,
  starting `hl` for its checks and `h` for each test.
- **`server stop` by absolute path:**
  `HC_SESSION=<s> ~/.local/bin/herdr-core server stop` with the same environment
  you started it in. It is the one subcommand that cannot start a core. `hc` and
  every other subcommand can, with whatever environment the caller has.
- **No `pkill` over SSH.** A pattern matches its own session's command line and
  kills the connection you are using. Kill a pid you read from `server.status`.
- **Key cleanup.** Authorize a throwaway key only, with a comment naming the run,
  and remove that line when you finish, also after a failure. Never use a real
  credential or sign in to a harness for this check.

## Scripted check

```bash
make verify-core-linux-host SIM_UDID=<udid> LAB=hc-lab
```

It authorizes a throwaway key through `instabox port-forward`, runs the seven
methods of `HerdrCoreTransportE2ETests` on the Simulator, then starts a core for a
unique session and checks:

- the `hc-serve-*` and `hc-hold-*` user units
- `loginctl show-user <user> -p Linger`
- the socket at `/run/user/<uid>/herdr-core/<s>.sock`
- frames captured by `scripts/lab/herdr-core-capture.py` replay through a decoder
  unchanged (saved under `.local/lab-capture/`; read them before keeping them)

It ends with every session it started stopped and removed, the key line gone, its
directory removed, the port-forward ended and the Simulator's variable unset. A
failed step reports `FAIL` and still cleans up. Confirm on the box afterwards:

```bash
grep -c heeler-lab ~/.ssh/authorized_keys
ls ~/.local/state/herdr-core
```

The first prints `0`, and the second lists only the sessions you had before. The
box has a real `hc`, so the tripwire that proves the app never calls it only exists
on the fixture.

## Connect states

Add the Host by hand with a unique core session, confirm **herdr-core** in its
detail, and run its checks in each state.

| State | How to get there | Heeler reads | Check again |
| --- | --- | --- | --- |
| Connected | A core started for the Host's session | All checks pass with the core's version | |
| Not installed | Rename `~/.local/bin/herdr-core` for the check, and restore it after | **herdr-core is not installed** | Needs you |
| Not running | `server stop` by absolute path, or a session never used | **herdr-core is not running** at the socket path; no `core.lock` or process appears | Retried |
| Not running, socket left behind | SIGKILL the pid from `server.status`, or refuse `AllowStreamLocalForwarding` | **herdr-core is not running**, naming both a stopped or crashed core and an SSH server refusing socket forwarding | Retried |
| Update required | A core older than the app needs | **herdr-core needs an update**, with `<path>/herdr-core update` by the path it found | Needs you |
| Socket path too long | A session name that takes the holder's socket past 107 bytes | **The herdr-core socket path is too long**, naming the path | Needs you |

Each check run must leave the Host as it found it: no core started, and no process
or file added.

## Start

Give the Host a unique non-default core session. The session is yours to start and stop; no other is. Record the session and
`loginctl show-user <user> -p Linger` before you begin. To see the linger step change
something, turn it off first with `loginctl disable-linger`, and put it back afterwards
if it was on.

| Step | What to do | What to check |
| --- | --- | --- |
| Offer | Open the Host with its core stopped | **herdr-core is not running**, with **Start herdr-core** below the checks. Rerun the checks a few times: `ls ~/.local/state/herdr-core` gains nothing |
| Confirmation | Tap **Start herdr-core** | It names the session, the interactive login shell and systemd linger. **Cancel** starts nothing |
| Fresh start | Tap **Start herdr-core**, then **Start** | The checks run again and pass, and the note says the session started. `<s>/core.lock` exists and no `default` directory appeared. `Linger=yes`. A Terminal started afterwards has the `PATH` the account's rc files set, not the SSH exec's |
| Linger note | Read the state you recorded against the one you read now | Off before and on now, or on both times |
| Already running | Stop the core and rerun the checks so **Start herdr-core** shows, then start the core on the box with `HC_SESSION=<s> ~/.local/bin/herdr-core server start` and tap **Start** in the app | **herdr-core was already running**, **Start changed nothing**, and no word about your environment. `server.status` shows the same `pid` as before the tap |

Stop the session by absolute path when you finish, as the safety rules say.

## Console

With a core running in your unique session and the Host connected, open the
Terminals tab. Start Terminals on the box, since a core Host offers no New Terminal
yet, and read each pid from `server.status` or `terminal.list`.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Derived Workspaces | Terminals launched in two directories | One card per directory, named for its last path component, with one row per Terminal; a row opens its Terminal and its menu offers only Copy Path |
| Kept restart | `kill -9` the program of a Terminal started with `keep` | The row reads **Restarting** with its launch directory, then comes back in the same card |
| Core restart | SIGKILL the pid from `server.status`, with a kept Terminal so its holder restarts the core | The Host stays Connected in the Hosts list and every row stays in its card |
| Stopped core | `server stop` by absolute path | The Host reads **herdr-core is not running** and retries; no core process appears until you start it |

## Attach

Open each Terminal from its row, and an Agent from the Agents tab. Every terminal is a
channel on the Host's one link, so `ss` on the box shows one connection however
many are open.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Full-screen program | Run `vim`, then `htop`, in a core Terminal and rotate the device | The program fills the terminal in both orientations and redraws at the new size |
| Scrollback | `seq 1 5000`, then scroll back | Earlier lines are there, in order |
| Burst and repaint | `head -c 6000000 /dev/urandom \| base64` with the terminal hidden or scrolled, so the core drops its backlog | The screen repaints and stays usable; the Terminals tab and another open terminal keep updating |
| Modes after a repaint | In `vim`, paste multi-line text after the burst above | The paste arrives bracketed, as one insert |
| Every key | `stty -isig; cat -v`, then Ctrl+\ | `cat` prints `^\`; nothing in Heeler intercepts it |
| Display facts | In a core Terminal, `stty raw -echo min 0 time 20; printf '\033]11;?\033\\\033[16t'; dd bs=256 count=1 2>/dev/null \| tr '\033' '^'; stty sane; echo`, then pick another theme in Settings and run it again | It prints the theme's background as `]11;rgb:…` and the cell in pixels as `[6;<height>;<width>t`; the second run shows the new background |
| Second viewer | `hc attach <terminal>` on the box at another size, then type in Heeler | The program takes Heeler's size when you type; no Take Over appears anywhere on the Host |
| Retained terminals | Open six Terminals in turn and go back | Five stay retained for five minutes and come back at once; the sixth detaches the least recently viewed idle one, which attaches afresh when you return to it |
| End of a program | `exit` in a Terminal, kept or not | **Terminal Closed** with **Back to Console**, and no error or **Reattach** |
| Agent detail | Open a core Agent | Live terminal, Changes and Skills work; Send, Stop and Add stay hidden; Direct Input types into the terminal |
| Two windows | On an iPad, show one core Agent in two windows, open Changes in the first and come back | Each window keeps a live terminal of its own, and typing in either reaches the program |
| Window size | On an iPad, resize a window showing a core Agent across compact and regular widths, then leave the Agent | The same terminal and scrollback stay on screen with one viewer, and the viewer closes five minutes after you leave |
| Closed window | On an iPad, close one of two windows showing the same core Agent | The other window's terminal stays live; if the closed window retained the Terminal, its viewer stops being reported and closes after five minutes; if it held the second viewer, that viewer closes at once and `terminal.get` shows the size follows the window left |
| Closed window on a Terminal | On an iPad, open a core Terminal in one window, close that window, then open the same Terminal in another | The other window shows the Terminal at once on the same channel and takes its size, with no "already open in another window". Left alone, the Terminal returns to its headless size within five minutes of the close |

## Reattach

Start a kept Terminal on the box with `terminal.run` and `keep` through
`scripts/fixtures/herdr-core-rpc.py`, and a harness or an inert program that reports
a status, so it is listed as an Agent. Read the program's pid from `terminal.list`,
and kill only that pid. The core brings a shell back about two seconds later.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Added plainly | Add the Host by hand, from a build launched with no arguments | **Use herdr-core** is offered, the Host connects, and `hc` was never called |
| Agent detail restarts | Open the Agent's detail, then `kill -9` the pid | **Restarting…** with no error and no **Reattach**, then the restored shell in the same detail, with nothing tapped. Typing reaches the new shell |
| Terminal restarts | Open a kept Terminal from its row, then `kill -9` the pid | The same, and `terminal.get` shows Heeler's size afterwards |
| Hidden while it restarts | Leave the terminal retained, `kill -9` the pid, and come back after the shell returned | The restored shell at once, attached with no error |
| Opened between programs | `kill -9` the pid and open its row within the two seconds | **Restarting…**, then the restored shell |
| Agent exits | In an open Agent detail on a Terminal not started with `keep`, quit the program | **Agent Ended**, with no **Reattach**, and `terminal.get` reads `finished` |
| Kept program exits | The same on a kept Terminal, with `exit` or a program exit code | **Agent Ended**, or **Terminal Closed** on its own screen: a kept Terminal comes back only from a loss |

## Program Status

With the Host connected, start each harness in its own Terminal on the box, and
compare the Agents tab with the event log `scripts/lab/herdr-core-capture.py` records
for the session. Use the mock API or a harness's local model, and never a real
credential. Which harness reports what is what this section finds out, so record the
version beside each result. Add any case the
[Agent-rule vector](../../plugin/test-vectors/herdr-core-agent-rule-v1.json) lacks,
with its source, and clear the vector's `provisional` flag once the captures are in.
The [Done step](#done-per-device) below does the same for the turn-end vector.

| Harness | Start it | Its `app` | Agent kind | Heeler shows |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` against the mock API | `claude-code` | `claude` | **Unknown** until its first report, then each report as the log has it. A permission prompt reads **Blocked** |
| Codex | `codex` against the mock API | `codex` | `codex` | The same |
| Pi | `pi`, from each package name you can install (`@mariozechner/pi-coding-agent`, `@earendil-works/pi-coding-agent`) | `pi` | `pi` | The same. A Node launch resolves to `pi` |
| OpenCode 2.x | `opencode` | `opencode` | `opencode` | The same |
| Oh My Pi | `omp` | `omp` | `omp` | The same |
| Grok Build | `grok` | `grok-build` | `grok` | The same. Without hooks set up it stays **Unknown** |

Each Agent lists on Agents, By Host and By Workspace, and under the Host filter. It
leaves the Terminals tab while it holds the foreground, its row opens its detail, and
its menu offers Open in New Window where the device has windows, and no Close.

Then check what no harness needs to be signed in for, from an inert program in a
Terminal. A status report is `printf '\033]7501;state=working:app=x\007'`, as the
[capture scenario](../../scripts/fixtures/herdr-core-capture-scenario.py) writes them.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Error | A running program reports `state=error` | **Error**, sorted with Blocked |
| Reported done | A running program reports `state=done` with no `working` before it | **Idle**. It finished no turn |
| Unknown app | A program that is not a shell reports an `app` Heeler does not know, or none | An Agent with a generic glyph and the program's word as its kind, and no Chat |
| Shell exit | Quit a harness back to its shell | The Agent ends and the row returns to the Terminals tab, whatever it last reported |
| Wrappers | A harness started through `bash -lc`, and through the desktop app's fish wrapper | The Agent is the harness underneath. New arguments on the fish wrapper's pid end it |
| Cleared foreground | Quit a harness started through the desktop app's bash wrapper, then run `printf x \| less` in the shell it left, and background and reopen Heeler while it runs | No Agent comes back, at the capture's `null` `foreground` event or after the reconnect |
| Kept restart | `kill -9` a harness started with `keep` | No Agent between `lost` and `restarted` |

## Done per device

Run this for Claude Code and Codex against the mock API, Pi, and OpenCode 2.x, with
the capture running, and the same Host added on a second device or Simulator with its
own Device Key. Record each version.

| Check | What to do | What to check |
| --- | --- | --- |
| Done while away | Give the Agent a prompt from another client, stay on the Agents list until it finishes | **Done** on the row, and on the second device |
| Open clears here | Open the Agent, go back | No **Done** on this device. The second device still shows **Done** |
| Open as it ends | Give it a prompt, keep its detail open until it finishes, go back | Never **Done** on this device. The second device shows **Done** |
| Working again | With **Done** showing, give it another prompt | **Working** in place of **Done** |
| Relaunch | Open one finished Agent, leave another, kill the app and relaunch | The opened one stays without **Done**, the other keeps it |
| Blocked, then done | Make Claude Code ask for permission, answer it, let it finish, without opening it | **Blocked**, **Working**, then **Done** |
| Codex start-up | Start Codex and leave it at its prompt | Its first working blip shows no **Done** |
| Not known to report done | OpenCode 2.x finishing a turn | **Done** from its move to idle |

Add any case the
[turn-end vector](../../plugin/test-vectors/herdr-core-turn-end-v1.json) lacks, with
its source, and clear its `provisional` flag once the captures are in.

## Agent Row Layout

Open **Settings**, then **Agent List Fields**, and the Host.

| Check | What to do | What to check |
| --- | --- | --- |
| Starting rows | Open a Host you have never edited | **Heeler's fields**, Row 1 `terminal_title_stripped`, Row 2 `directory`, Row 3 empty. No **Sync from plugin**, and no word of Sync or the plugin on the page |
| Labels | Label a Terminal on the box, then add a field to a row | The label is offered under **Terminal labels**, and the Agents tab shows its value. No `$` field and no `state_text` is offered |
| Herdr TUI beside it | Open a Herdr TUI Host | **Sync from plugin**, its copy and its fields as before |

## Pins

With a core running in your unique session and two Agents listed, from inert programs if you like. Removing a Terminal takes
`terminal.kill` then `terminal.rm` through `scripts/fixtures/herdr-core-rpc.py`, since
`terminal.rm` refuses a running one.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Pin | Long-press the lower Agent, then **Pin** | It moves to the top of the Agents tab with its pin mark, and stays there after you force-quit and reopen the app |
| Removed while connected | Remove a pinned Terminal | Its row goes. The Host's other Pins stay |
| Removed while away | Force-quit the app, remove a pinned Terminal, reopen | Its Pin is gone once the Host connects, and starting another Terminal does not bring it back |
| Core restart | SIGKILL the pid from `server.status`, with a kept Terminal so its holder restarts the core | Every Pin stays, and the pinned rows return to the top |
| Wiped core | **Only on a throwaway session.** `server stop` by absolute path, delete `~/.local/state/herdr-core/<s>`, start the core again and start a Terminal in it | All of this Host's Pins are gone, the new Terminal is unpinned even at an address a Pin had, and a second Host's Pins stay |
| Herdr TUI beside it | Pin an Agent on a Herdr TUI Host and close its pane on the box | The Pin stays, and the same pane id coming back is pinned |

## Leaked environment

On a throwaway session, start the core by absolute path with made-up values for
variables that break things, then read Host detail. Never use a real value of
these, and never use a session you did not start.

```sh
HC_SESSION=<s> TMUX=/tmp/made-up,1,0 CLAUDE_CODE_CHILD_SESSION=made-up STY= \
  ~/.local/bin/herdr-core server start
```

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Leaked variables | The core above, with the Host connected | **Core Environment** names `CLAUDE_CODE_CHILD_SESSION` and `TMUX`, each with what it breaks, and says restarting the core from your own terminal fixes it; blank `STY` is not named, no value appears, and nothing offers a restart |
| Prefix | Add `HERDR_PANE_ID=made-up` when starting | `HERDR_PANE_ID` is named with the others |
| Restarted cleanly | `server stop` by absolute path with the same environment, then start again from a clean login shell without those variables | The Host reconnects by itself and **Core Environment** is gone |

## Desktop organization

With a core running in your unique session and the Host connected, open the
Terminals tab. Set labels with `terminal.label` through
`scripts/fixtures/herdr-core-rpc.py`, which never starts a core. Only on a throwaway
session, seed a document with `doc.set`. On a core the desktop app runs on, never
call `doc.set`: the app answers a conflict by replacing its own layout. Heeler only
reads `herdr-app`, so `doc.get` shows the same `version` before and after anything
done in the app.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Labeled Terminals | `herdr.space` and `herdr.tab` naming a space and tab in the document | The space's card under its name, in the document's order, above any derived Workspace, with the row reading **Tab “name”** |
| Unnamed tab | A tab whose document name is empty | **Tab N**, N being its place among the space's tabs in the document |
| Label-only space | `herdr.space` naming a space no document lists, in a directory inside a git checkout | A card named for the checkout's folder, after the document's spaces; asked once per directory |
| Space outside git | The same, in a directory outside any checkout | A card named for that directory, or **~** in the home directory |
| Child Terminal | `terminal.run` with `parent` and no `herdr.*` label, `heeler.*` labels allowed | Another row in its parent's card, reading the parent's tab |
| Child with its own labels | The same with `herdr.space` and `herdr.tab` | A row in the space its labels name |
| Live change | Rename or reorder in the document, or set or clear a label | The cards follow within a moment, without reconnecting |
| Mac with the desktop app | Add that Mac as a herdr-core Host | The same spaces and tabs as the window, in its order and under its names; a space the app has not named reads the same in both |

## Detection states

Add a Host by hand and read its Server Kind section before confirming. Tap **Run Checks Again** after changing a state.

| State | How to get there | herdr-core row reads |
| --- | --- | --- |
| Not installed | Rename `~/.local/bin/herdr-core` for the check, and restore it after | **Not installed** |
| Not running | `server stop` by absolute path, or a session never used | The core's version, then **not running** |

Detection must leave the Host as it found it too: no core or herdr server started.

## Host Helper

Use a Host whose user has never had the Helper, with linger off. Before installing,
save `find ~/.local/share ~/.config/systemd ~/.pi ~/.omp -print 2>/dev/null | sort` so
the end of the run can compare against it. For the extension steps, have Pi and Oh My
Pi installed, signed in with an account of the Host's own, with one Oh My Pi profile
besides the default (`omp --profile work` makes one).

| Step | What to do | What must happen |
| --- | --- | --- |
| Install | Open the Host's detail, tap **Host Helper**, read the sheet, and tap **Install** | The sheet lists every file, the unit included, and those are the files on the Host. `XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user status heeler-host-helper` is active, with the absolute Node.js path in its `ExecStart` |
| Privacy | `ls -la` the Helper directory, its `app` folder and the unit | Directories `0700`, files `0600` |
| Linger | Read the row with linger off, then tap **Turn On Linger** | The row reads **Linger Off**, the sheet offers linger, and `loginctl show-user $USER -p Linger` then reads `yes`. On a Host that asks for an administrator, the sheet shows the Host's reason |
| Log out | End every login to the Host, wait a minute, and log back in | The Helper kept running: the same main PID, with no restart counted |
| Restart | `kill -9` the Helper's Node.js process | systemd starts it again within seconds, `NRestarts` goes up by one, and the row still reads the version |
| Node.js moved | Rename the Node.js executable, kill the Helper, wait past the start limit, then check the Host | The unit is `failed` with result `start-limit-hit`, and the row reads **Service Failed** or **Node.js Missing**. Restore Node.js and tap **Repair**: it runs again |
| Damage | Change a byte in `app/main.js`, then check the Host | The row reads **Damaged**, and **Repair** puts the file back and keeps `notifications.json` |
| Extensions listed | Read the sheet before installing | It lists `heeler-session.js` in `~/.pi/agent/extensions`, `~/.omp/agent/extensions` and `~/.omp/profiles/work/agent/extensions`, and those are the files on the Host afterwards. `installed.json` names each one, and each folder the install created |
| Pi label | Start Pi in a core Terminal, then `/new` | The Terminal's `heeler.session` label is JSON naming the session id, its file, Pi's pid and `start`, the process's `/proc/<pid>/stat` field 22. `/new` rewrites it with the new session |
| Oh My Pi label | Start `omp` and `omp --profile work` in core Terminals, then `/new` in one | Each carries the same label, with a session file under its own profile. `/new` rewrites it (source review only so far: the spike's run stopped at the first-run welcome) |
| Inert outside | Start the same programs outside herdr-core, with no `HC_TERMINAL_ID` | They behave as before, and nothing connects to the core's socket |
| Slow socket | Start Pi in a core Terminal with `HC_TERMINAL_SOCKET` pointing at a socket that accepts and never answers | Pi starts as usual, with no delay and no message on screen |
| Pi status | Run Pi 1.0.4 and Pi 1.4.0 in core Terminals through a prompt | 1.0.4 reports idle, working and done through the extension, with an intact screen during the run, which the spike could not test without a model. 1.4.0 reports for itself, and `app=pi` reports do not double |
| New profile | Make another Oh My Pi profile, then check the Host | The row still reads the version, and the sheet offers **Repair**, which adds that profile's file and touches no other file of the Helper |
| Remove | Tap **Remove** and confirm | The unit is gone and inactive, the Helper directory and every folder the install created are gone, no `heeler-session.js` is left, and the saved listing matches again. Linger stays on, and the Grok Build setting is untouched |

Every step must leave the core as it found it: the Helper in this version only follows
a core, and never starts one. The extensions only ever write the one label on their own
Terminal.

### The Helper and the core

Until the app registers devices with the Helper, name the session by hand, in the
Helper directory: `printf '{"v":1,"devices":[{"session":"default"}]}' >
~/.local/share/heeler/host-helper/notifications.json`. Remove the file when done.

| Step | What to do | What must happen |
| --- | --- | --- |
| No core | Stop the session's core with `herdr-core server stop` by absolute path, then `systemctl --user restart heeler-host-helper` | `systemctl --user list-units 'hc-serve-*'` shows no new unit, however long you wait. `journalctl --user -u heeler-host-helper` reads `core session "default": waiting for a core at <socket>` once |
| Core starts | Start the core from the user's login shell, and do not touch the Helper | Within seconds the journal reads `connected to core pid <pid>`, the pid `server.status` reports. The unit's main PID has not changed |
| Core restarts | `kill -9` the core at that pid, then start it again from the login shell | The journal reads `connection to core pid <pid> ended`, then `connected` with the new pid |
| Other sessions | Start a core for a session the file does not name, and no Host's Usage asked about | The journal never mentions it, and `ss -xp` shows the Helper connected only to the named session's socket |

### Usage

Use a throwaway `CLAUDE_CONFIG_DIR`, for example `~/heeler-usage-lab`, that the SSH session's environment lacks, and put a small Transcript with known token counts under its `projects/`. Add a unique marker to the core's environment, `HEELER_LAB_MARKER=not-listed`. Add the Host with the session you start. Never sign in to a harness for these steps, and leave out **Claude Code limits** unless the Host has a throwaway sign-in. Remove the directory when done.

| Step | What to do | What must happen |
| --- | --- | --- |
| No Helper | Open Usage before installing, with the core running and again with it stopped | The Host's Usage reads **Usage needs the Host Helper**, and the Usage tab and widget leave it out of their totals as **Needs the Host Helper**, both times. Nothing is added to the Host |
| Waiting | Install the Helper, stop the session's core, and open Usage | In the Usage tab too, not **Not connected**: **The Host Helper has not reached this session's core yet**. `~/.local/share/heeler/host-helper/sessions/<session>` is there, `0700`. `systemctl --user list-units 'hc-serve-*'` shows no new unit, however long you wait |
| Core's environment | Start the core from a login shell with `CLAUDE_CONFIG_DIR` and the marker set, and do not touch Usage | Within a minute Usage shows the Transcript's tokens under the Default Account, and so does the Usage widget, with no notification registration on the Host. `sessions/<session>/runtime.json` is `0600` and names that directory |
| Only named variables | `grep -c HEELER_LAB_MARKER` the record, then `journalctl --user -u heeler-host-helper \| grep -c not-listed` | Both print `0`. The journal reads the core's pid, and no value |
| Core restarts | Restart the core with another `CLAUDE_CONFIG_DIR` | The record names the new directory, and Usage follows after the next read |
| Suggestions | Start Claude Code in a core Terminal with a third directory as `CLAUDE_CONFIG_DIR`, whether or not it is signed in, and open **Claude Code Accounts** | That directory is suggested. Adding it writes `usage-accounts.json` in the Helper's directory, `0600`, and nothing under `~/.config/herdr` |
| Limits | With a throwaway sign-in, turn on **Claude Code limits** for this Host, then off | A read asks only while it is on, and the card follows. Skip this without such a sign-in |
| Update | Install a Helper from before Usage, and open Usage | **Usage needs a newer Host Helper**, until you update it from the Host's detail |
| Unreachable | Stop `sshd` or block the route, and open Usage | The Usage tab leaves the Host out as **Not connected** |
| Widget alone | Add a Usage widget. With the core stopped and no Helper, reopen Heeler and do not open Usage. Repeat on an unreachable Host, and on a native Windows Host if one is on hand | The widget says **Needs the Host Helper**, **Not connected**, and **Comes with the Host Helper, not available yet**, and keeps saying so after you force-quit Heeler and reopen it. None of them reads **Not read yet** |

`/proc/<pid>/environ` holds the environment the core started with, so a variable it set for itself later does not appear. A Windows Host's line is covered by unit tests, not this checklist.
