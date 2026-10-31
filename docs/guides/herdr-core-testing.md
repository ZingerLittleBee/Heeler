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

It authorizes a throwaway key through `instabox port-forward`, runs the five
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

Launch the app with `--offer-herdr-core-hosts` unless the build already offers
herdr-core. Add the Host by hand with a unique core session, confirm **herdr-core**
in its detail, and run its checks in each state.

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

Launch with `--offer-herdr-core-hosts`, and give the Host a unique non-default core
session. The session is yours to start and stop; no other is. Record the session and
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
| Derived Workspaces | Terminals launched in two directories | One card per directory, named for its last path component, with one row per Terminal; the rows open nothing and their menu offers only Copy Path |
| Kept restart | `kill -9` the program of a Terminal started with `keep` | The row reads **Restarting** with its launch directory, then comes back in the same card |
| Core restart | SIGKILL the pid from `server.status`, with a kept Terminal so its holder restarts the core | The Host stays Connected in the Hosts list and every row stays in its card |
| Stopped core | `server stop` by absolute path | The Host reads **herdr-core is not running** and retries; no core process appears until you start it |

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

## Detection states

Add a Host by hand, with `--offer-herdr-core-hosts`, and read its Server Kind section
before confirming. Tap **Run Checks Again** after changing a state.

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
| Other sessions | Start a core for a session the file does not name | The journal never mentions it, and `ss -xp` shows the Helper connected only to the named session's socket |
