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

## Program Status

With the Host connected, start each harness in its own Terminal on the box, and
compare the Agents tab with the event log `scripts/lab/herdr-core-capture.py` records
for the session. Use the mock API or a harness's local model, and never a real
credential. Which harness reports what is what this section finds out, so record the
version beside each result. Add any case the
[Agent-rule vector](../../plugin/test-vectors/herdr-core-agent-rule-v1.json) lacks,
with its source, and clear the vector's `provisional` flag once the captures are in.

| Harness | Start it | Its `app` | Agent kind | Heeler shows |
| --- | --- | --- | --- | --- |
| Claude Code | `claude` against the mock API | `claude-code` | `claude` | **Unknown** until its first report, then each report as the log has it. A permission prompt reads **Blocked** |
| Codex | `codex` against the mock API | `codex` | `codex` | The same |
| Pi | `pi`, from each package name you can install (`@mariozechner/pi-coding-agent`, `@earendil-works/pi-coding-agent`) | `pi` | `pi` | The same. A Node launch resolves to `pi` |
| OpenCode 2.x | `opencode` | `opencode` | `opencode` | The same |
| Oh My Pi | `omp` | `omp` | `omp` | The same |
| Grok Build | `grok` | `grok-build` | `grok` | The same. Without hooks set up it stays **Unknown** |

Each Agent lists on Agents, By Host and By Workspace, and under the Host filter. It
leaves the Terminals tab while it holds the foreground, its row opens nothing, and its
menu offers no Open in New Window or Close.

Then check what no harness needs to be signed in for, from an inert program in a
Terminal. A status report is `printf '\033]7501;state=working:app=x\007'`, as the
[capture scenario](../../scripts/fixtures/herdr-core-capture-scenario.py) writes them.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Error | A running program reports `state=error` | **Error**, sorted with Blocked |
| Reported done | A running program reports `state=done` | **Idle**. Done per device is a later check |
| Unknown app | A program that is not a shell reports an `app` Heeler does not know, or none | An Agent with a generic glyph and the program's word as its kind, and no Chat |
| Shell exit | Quit a harness back to its shell | The Agent ends and the row returns to the Terminals tab, whatever it last reported |
| Wrappers | A harness started through `bash -lc`, and through the desktop app's fish wrapper | The Agent is the harness underneath. New arguments on the fish wrapper's pid end it |
| Kept restart | `kill -9` a harness started with `keep` | No Agent between `lost` and `restarted` |

## Agent Row Layout

Open **Settings**, then **Agent List Fields**, and the Host.

| Check | What to do | What to check |
| --- | --- | --- |
| Starting rows | Open a Host you have never edited | **Heeler's fields**, Row 1 `terminal_title_stripped`, Row 2 `directory`, Row 3 empty. No **Sync from plugin**, and no word of Sync or the plugin on the page |
| Labels | Label a Terminal on the box, then add a field to a row | The label is offered under **Terminal labels**, and the Agents tab shows its value. No `$` field and no `state_text` is offered |
| Herdr TUI beside it | Open a Herdr TUI Host | **Sync from plugin**, its copy and its fields as before |

## Detection states

Add a Host by hand, with `--offer-herdr-core-hosts`, and read its Server Kind section
before confirming. Tap **Run Checks Again** after changing a state.

| State | How to get there | herdr-core row reads |
| --- | --- | --- |
| Not installed | Rename `~/.local/bin/herdr-core` for the check, and restore it after | **Not installed** |
| Not running | `server stop` by absolute path, or a session never used | The core's version, then **not running** |

Detection must leave the Host as it found it too: no core or herdr server started.
