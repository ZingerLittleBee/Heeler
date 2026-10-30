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

It authorizes a throwaway key through `instabox port-forward`, runs the three
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

## Detection states

Add a Host by hand, with `--offer-herdr-core-hosts`, and read its Server Kind section
before confirming. Tap **Run Checks Again** after changing a state.

| State | How to get there | herdr-core row reads |
| --- | --- | --- |
| Not installed | Rename `~/.local/bin/herdr-core` for the check, and restore it after | **Not installed** |
| Not running | `server stop` by absolute path, or a session never used | The core's version, then **not running** |

Detection must leave the Host as it found it too: no core or herdr server started.
