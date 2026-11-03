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
  and remove that line when you finish, also after a failure.
- **No sign-in, unless the owner approves a signed-in run.** Never use a real credential
  or sign in to a harness, except for the signed-in checks
  ([Codex, Grok Build and OpenCode](#codex-grok-build-and-opencode),
  [Choosing a conversation](#choosing-a-conversation), [OpenCode edit](#opencode-edit),
  [Pi and Oh My Pi Chat](#pi-and-oh-my-pi-chat)) in a run the owner has approved. Keep
  that run's harness configuration in directories of its own, or use the account's real
  HOME: then back up every folder the harnesses write, with contents, modes and mtimes,
  before the first start, and restore each one at the end. Harnesses also write caches and
  logs outside those folders, so sweep HOME and `/tmp` by birth time (`stat -c %W`) before
  the run's directory goes.
- **Sign out before restoring.** Run `codex logout` and check that `codex login status`
  reads `Not logged in`, and `grok logout`, whose second run says there is no cached
  session, before the folders are restored. Both show the local state only: whether the
  provider revoked the session has not been seen.
- **The box's browser.** A device login can finish in the box's own browser and leave the
  identity provider's session in its profile. After the logins, look for that provider's
  cookies there, and sign out or clear them unless the owner decides to keep them.
- **A Simulator another run shares.** Export the app's preferences before adding a Host,
  and undo only your own: **Remove Host** in the app, then delete that Host's entries in
  `knownHostFingerprints` and `recent-workspace-by-host`, which Remove Host leaves behind
  (once it left a Pin too), and compare the export with the one from before. Never delete
  `herdrCoreHosts`, `knownHostFingerprints` or another shared key whole, since another
  run's Host lives in them too, and do not rely on `defaults import` alone: it merges, so
  keys the run added stay.
- **The data container.** Read it with
  `xcrun simctl get_app_container <udid> dev.bybee.heeler data` when you need it, not from
  earlier notes, which once named the wrong one.
- **The clipboard.** The Simulator shares the Mac's clipboard both ways. Before a paste
  test, put placeholder text on the Mac's clipboard, since whatever is there shows in
  **Review Paste**. **Add Image** and **Add File** copy the staged path, and in the
  2026-11-02 run that copy replaced the Mac's clipboard too, which then read as empty
  text. Save the Mac's clipboard before them and put it back after.

## Scripted check

```bash
make verify-core-linux-host SIMULATOR_UDID=<udid> LAB=hc-lab
```

It authorizes a throwaway key through `instabox port-forward`, writes the fixture's
startup files into its own directory for the launch method, so the account's own
stay as they are, runs the nine methods of `HerdrCoreTransportE2ETests` on the
Simulator, then starts a core for a unique session and checks:

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
Terminals tab. Start Terminals on the box, and read each pid from `server.status` or
`terminal.list`.

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
| Second viewer | `HC_SESSION=<s> ~/.local/bin/herdr-core attach <terminal>` on the box at another size, for the Host's running session, then type in Heeler | The program takes Heeler's size when you type; no Take Over appears anywhere on the Host |
| Retained terminals | Open six Terminals in turn and go back | Five stay retained for five minutes and come back at once; the sixth detaches the least recently viewed idle one, which attaches afresh when you return to it |
| End of a program | `exit` in a Terminal, kept or not | **Terminal Closed** with **Back to Console**, and no error or **Reattach** |
| Agent detail | Open a core Agent | Live terminal works; on macOS and Linux, Changes and Skills work, and native Windows offers neither; Send and Stop work, and Add stages an image and a file, on macOS, Linux and native Windows (section 9 of the native Windows testing guide); Direct Input types into the terminal |
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
| Grok Build | `grok` | `grok-build` | `grok` | The same. With its Program Status off it stays **Unknown**, and [the edit](#grok-build-edit) is offered |

Each Agent lists on Agents, By Host and By Workspace, and under the Host filter. It
leaves the Terminals tab while it holds the foreground, its row opens its detail, and
its menu offers Open in New Window where the device has windows, and Close.

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
| Why Unknown | Tap **Unknown** on an inert program named `claude`, then on one named for no harness | The first names Claude Code 2.1.295, the second names no release, and neither offers an edit |
| Reported, no state | A running program reports `state=clear`, and tap **Unknown** | It has not reported a state yet, with no edit offered, whatever the program |

### Grok Build edit

On a throwaway session, start the core by absolute path with a made-up `TMUX`, as in
[Leaked environment](#leaked-environment), and start `grok` in a Terminal. Save a copy
of `~/.grok/config.toml` first, or note that it is absent. Do not sign in with a real
account.

| Step | What to do | What must happen |
| --- | --- | --- |
| Offer | Open the Agent and tap **Unknown** | **Turn On Grok Build's Status** shows, and the file has not changed |
| Shown change | Tap it | The file's path and the exact lines, `program_status = "on"` under `[ui.notifications]`. The file still has not changed |
| Changed under it | Add a comment to the file on the box, then tap **Apply This Change** | **The file changed after Heeler read it, so nothing was written**, and the file keeps your comment. Remove the comment, and tap **OK** |
| Apply | Review again and tap **Apply This Change** | `diff` against the saved copy shows exactly the lines shown. The mode is unchanged, and no `.heeler-` file is left beside it |
| Reports | Quit Grok Build and start it again | Record the version and whether a status arrives under the leaked `TMUX` in [the compatibility notes](../agents/herdr-compatibility.md). Source review could not settle this. Once it reports, its Agent shows no offer |
| Host detail | Open the Host's detail | **Harness Edits** lists Grok Build with the same lines and **Undo** |
| Undo | Tap **Undo** there | The file matches the saved copy byte for byte, or is gone again if it was absent, and the row goes |
| Undo refused | Apply again, add a comment on the box, and tap **Undo** | **The file changed after Heeler edited it, so nothing was written**, and the file keeps your comment. **Stop Listing** drops the row and leaves the file alone |
| A second file | With the edit applied, start another `grok` with `GROK_HOME` naming a scratch folder, and tap its **Unknown** | The offer shows, not the first file's edit. Apply shows that folder's `config.toml`, and **Harness Edits** lists both files. **Undo** on the first file's row restores that file and leaves the other |
| Symlink | Make the file a symlink and repeat Apply and Undo | It stays a symlink, and the target takes the change |
| Others untouched | Compare Claude Code's settings, Codex's hooks and `~/.grok`'s global hooks before and after | No change |

### OpenCode edit

Run this once with OpenCode 1.x and once with 2.x, each signed in with the lab's account, with Chat on for OpenCode in the build. Save a copy of `~/.config/opencode` first, or note that it is absent. Take a zoomed screenshot of each sheet.

| Step | What to do | What must happen |
| --- | --- | --- |
| Offer | Start `opencode` by hand, and on 2.x also with `hc run` and from a Template, then open Chat | **Can't Tell the Conversation** with **Let Chat Follow OpenCode…**, and nothing has changed on the Host |
| Shown change | Tap it, then **Review the Change** | The file (`tui.json` or `tui.jsonc` on 1.x, `cli.json` on 2.x), the folder and its three files. For a file that exists, the one line `"./heeler-opencode"`; for one that does not, the whole new file, with its `$schema` and the plugin list holding `"./heeler-opencode"`. Still nothing has changed |
| Changed under it | Add a comment to the file on the box, then tap **Apply This Change**. With no such file, write one with a comment after the review instead | **The file changed after Heeler read it, so nothing was written**, no folder appeared, and the file keeps your comment. Remove the comment, or the file you wrote, and tap **OK** |
| Apply | Review again and tap **Apply This Change** | `diff` against the saved copy shows the one entry and the folder, and no `.heeler-` file is left beside them |
| Binds | Quit OpenCode, start it again the same way, and open a conversation | The label `heeler.session` names it with the process's pid and start, and Chat binds. On 1.x Chat shows the conversation from 1.x's tables |
| `/new` | Run `/new` and send a prompt, then pick the first conversation in OpenCode's list | A new label each time, and Chat follows |
| Wrong list | Record in [the compatibility notes](../agents/herdr-compatibility.md) the plugin list's form on each release you ran | Provisional from source until this step |
| Host detail | Open the Host's detail | **Harness Edits** lists OpenCode with the same lines, the folder and **Undo** |
| Undo | Tap **Undo** there | The file matches the saved copy byte for byte, or is gone again if it was absent, the folder is gone, and the row goes |
| Undo a changed file | Apply again, change another setting in the file, and tap **Undo** | The entry goes, your setting stays, and the folder is gone |
| Apply again | Apply once more | The same change as the first |
| Remove the Helper | With the edit applied, remove the Host Helper | The service stops, its listed files and folders go, the entry and then the folder go, and then the Helper's directory. `diff -r` against the saved copy is clean, and the row goes. **Known defect**, seen once with OpenCode 2.2.2, Host Helper 0.5.3 and herdr-core 0.1.13: with both the 1.x and 2.x edits applied and OpenCode 2.2.2 running, the removal deleted `cli.json` before `tui.json`, OpenCode migrated `tui.json` into a new `cli.json` naming the deleted folder, and `diff -r` was clean only after quitting OpenCode and deleting that file by hand. Record whether OpenCode was running |
| No edit | Install the Helper and remove it with no edit applied | No OpenCode file is touched |
| Others untouched | Compare `opencode.json` and every other file in `~/.config/opencode` before and after | No change. `~/.local/state/opencode` is OpenCode's own state, not a setting, and does not count: OpenCode 2.x keeps a `heeler.opencode.session` entry in its `plugin-meta.json` there after Undo and after the Helper's removal |
| Herdr TUI | Open Chat for OpenCode on a Herdr TUI Host | Its session comes from herdr, with no offer |

A Mac run of 2026-11-02 with OpenCode 2.0.32 passed Offer by hand, Shown change, Apply, Binds by hand and with `hc run`, `/new`, Wrong list, Host detail, Undo, Apply again, Remove the Helper, and Others untouched within `~/.config/opencode` ([herdr compatibility](../agents/herdr-compatibility.md)). OpenCode 1.x, Changed under it, Undo a changed file, No edit and Herdr TUI were not run there.

A signed-in hc-lab run of 2026-11-03 (Debian 13, herdr-core 0.1.13, OpenCode 2.2.2 and 1.19.5 on the owner's endpoint, Host Helper 0.5.3, a debug build with every program in `confirmedLinuxCoreChatPrograms`) passed Offer with `hc run` on 2.2.2, Shown change and Changed under it with no file before, Apply, Binds and `/new` on 2.2.2 (a pick in its `/sessions` list was followed too), Host detail, Undo, Apply again, and Others untouched within `~/.config/opencode`; the `plugin-meta.json` entry that row names was seen on 2.2.2. The plugin list was `plugins` in `cli.json` on 2.2.2 and `plugin` in `tui.json` on 1.19.5. On 1.19.5 the label named each conversation and followed `/new`, but Chat read **No Messages Yet** with the status Unknown, and the 1.x edit was offered only while the login shell's `opencode` was 1.19.5: with 2.2.2 there, a 1.19.5 Agent was offered the 2.x `cli.json`, which 1.19.5 ignores. Remove the Helper failed: with both edits applied and OpenCode 2.2.2 still running, 2.2.2 migrated `tui.json` into a new `cli.json` during the removal, naming the deleted folder, and `diff -r` was clean only after quitting OpenCode and deleting that file by hand. Offer by hand and from a Template, Undo a changed file, No edit and Herdr TUI were not run there.

## Composer Send

`composerPasteThenSubmit` holds the bytes against a stub on the scripted check's real
core. These steps need the harnesses themselves, a real account's shell, or a slow
link. Record each version, and each result beside the check it answers.

| Check | What to do | What to check |
| --- | --- | --- |
| Claude Code, Codex, Pi | Run Claude Code and Codex against the mock API, and Pi, each in a core Terminal. Send a multi-line message from the Composer | The whole message reaches the Agent as one message and it starts working. The Composer shows it delivered |
| Blocked | Make Claude Code ask for permission, then Send | The text appears in its input, nothing answers the dialog, and the tools keyboard comes up to submit or cancel. **Known defect**, seen on 2026-11-02 with Claude Code 2.1.316 on herdr-core 0.1.13: the draft cleared and the text never showed, during the dialog or after Esc, while a stand-in that logs its bytes got the paste and no Enter. Native Windows step 22 saw the same with that version |
| Not accepting a paste | A program in a core Terminal with bracketed paste off, as `cat`, then Send | Nothing reaches it. The draft stays and the notice says **not accepting a paste** |
| Exit race | Under each of bash, fish and dash, start an Agent stand-in that exits as it reads a paste, with the desktop app's wrapper so its shell continues under the same pid (`composerPasteThenSubmit` has the program), then Send `touch /tmp/sent-to-shell` | No file. The shell's line is empty, the draft stays, and the notice says **no longer in the terminal**. Note any shell whose line keeps the text |
| Child note | With a Claude Code parent, make an `hc run` child exit during the two seconds after a Send, so the core types its note | Record what reached the Agent: the message, the note, and whether the note's Enter submitted them together. ADR 0035's two seconds exist to bound this |
| Slow link | Run Heeler through a weak-network proxy that delays each way by more than two seconds, then Send to an idle Agent | Nothing is submitted, the text stays in the Agent's input, and the notice says **stayed in the Agent's input unsubmitted**. With replies dropped entirely, the Composer shows the unanswered row, with **Edit Draft** and no Retry, and nothing arrives twice |

### zsh and one Ctrl+C

Use a throwaway account whose login shell is zsh. It needs a real account because what
zsh does with a paste it is still reading depends on its line editor. Run the exit race
above, and look at the prompt line after Send's Ctrl+C.

Until this is recorded, Send presses Ctrl+C under zsh and always says **may still be in
the terminal**. The conservative part is that notice, never skipping the Ctrl+C. If zsh
drops the text, add it to `shellsDroppingPasteOnInterrupt` in `HerdrCoreComposerSend`.
If it keeps the text, amend [ADR 0035](../adr/0035-herdr-core-composer-sends-through-the-attach.md)
so Send skips Ctrl+C under zsh while still saying so. Either way, record the result in
[herdr compatibility](../agents/herdr-compatibility.md).

## Chat evidence

Run Claude Code against the mock API in core Terminals of a throwaway session on a
Linux box, signed in to nothing. Record its version, and the raw value beside each
check that asks for one. The binder's tests read a fake process tree, and these are
the facts they took on trust, so correct
[herdr compatibility](../agents/herdr-compatibility.md) with whatever differs.

| Check | What to do | What to check |
| --- | --- | --- |
| Binds at its prompt | Start Claude Code from New Agent, wait for its prompt, send one message from the terminal, open Chat | The conversation shows. Record `procStart` in `<config dir>/sessions/<pid>.json` beside field 22 of `/proc/<pid>/stat`: they are equal |
| Started by hand | Start `claude` from a shell in a Terminal the Agents tab lists, then open Chat | The same conversation binding, with no `heeler.*` label on the Terminal |
| Launchers | Run an npm-installed `claude`, through `npx` too, and a shell script that runs it, then open Chat | The npm and `npx` ones bind; the core's foreground under `npx` reads `npm exec claude`. The script lists as a Terminal, not an Agent, since a script is its own program (ADR 0032). Record each process's name from `/proc/<pid>/stat`, and that each shares the Terminal's `HC_SCOPE`. Record what the native installer's binary calls itself |
| Before its prompt | Use a fresh config dir and stop at the trust dialog, then open Chat | **Can't Tell the Conversation**. No `*.key` file is read. Answer the dialog: Chat follows on the status change, with no Retry |
| `/clear` and `/resume` | In an open Chat, run each in the terminal | Chat shows the new conversation by the next status change |
| Own config dir | Start with `CLAUDE_CONFIG_DIR` naming a scratch folder, while `~/.claude` holds other sessions | Chat reads from the scratch folder |
| Leaked variable | Start `CLAUDE_CODE_CHILD_SESSION=1 claude`, then `CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 claude`, each with the mock API | **Transcript Saving Is Off** names the variable, and the sessions folder and project folder hold what it says they do |
| Carried by the core | Use the core from [Leaked environment](#leaked-environment), then start `claude` by hand | The same reason, also pointing at the Host's details, where **Core Environment** names it |
| Stale hint | Set the label `heeler.session` on the Terminal with `terminal.label`, holding another pid, then open Chat | The label is gone and Chat does not show the label's session |
| No polling | With the Host's sshd logging exec requests, keep Chat open on an idle Agent for five minutes | No exec during that time. One status change costs one exec and one read of `sessions/<pid>.json` |
| Off elsewhere | A Pi Agent on this box | It offers the terminal alone |

### Codex, Grok Build and OpenCode

These are the owner's checks on hc-lab, with a harness you sign in to, that decide
whether a program joins `HostCapabilities.confirmedLinuxCoreChatPrograms`. A Mac has
its own list, from [Chat on a Mac](#chat-on-a-mac). For each program that passes, add it
there and record the versions in
[herdr compatibility](../agents/herdr-compatibility.md), and for one that fails, record
what differed and leave it off. The binder's tests read recordings made with a fake
model and no account, so also correct the observation for whatever a signed-in run
shows.

| Check | What to do | What to check |
| --- | --- | --- |
| Codex without the daemon | Start Codex from New Agent, send one message, open Chat | The conversation shows, from the rollout its native process holds under its own `CODEX_HOME`. Record the process tree and each held rollout's `session_meta` |
| Codex by default | Start plain `codex` in a Terminal, send one message, open Chat | **Codex Started Without `--no-daemon`** names `codex resume --no-daemon`, Chat reads nothing and sends nothing. Do what it says. While the shared daemon still holds the conversation, `codex resume --no-daemon` does not open it: run `codex app-server daemon stop` first, and then the conversation shows. Record the control socket's path, which came from Codex's source, and the daemon's version |
| A second default Codex | Start a second plain `codex` on the same `CODEX_HOME`, then open its Chat | The same message, on a Terminal with no daemon under it |
| Codex's `/new` | In an open no-daemon Chat, run `/new` (in a git repository Codex first asks where the new conversation runs), then send a message in the terminal, returning to Chat after each step | Right after `/new`, Chat keeps the old thread's messages under the banner that it can't tell which conversation this Agent is in now, with **Choose a Conversation**: the new thread's lock is held beside the old rollout and its lock. With the first message Codex creates the new rollout and holds it too. The banner stays, and a Send from Chat sends nothing. Record the held files at each step |
| Grok Build | Start Grok Build from New Agent, open Chat before any message, then send one | Chat waits for the first message, then shows the conversation under the `GROK_HOME` it runs with. Record its row in `active_sessions.json` beside field 22 of `/proc/<pid>/stat`. **Known defect**, seen once with Grok Build 1.0.70 on herdr-core 0.1.13: a Chat opened before the first message stays on **Can't Tell the Conversation** until **Check Again** |
| Grok Build's `/new` | In an open Chat, run `/new`, then send one message in the terminal | Chat keeps the old conversation's messages under the banner that it can't tell which conversation this Agent is in now, with **Choose a Conversation**, not the full **Can't Tell the Conversation** view. `active_sessions.json` holds two rows for one process |
| OpenCode 2.x | Start OpenCode 2.1 or later from New Agent, open Chat before any prompt, then send one from the terminal | Chat waits for the first message, then shows the conversation from the store. Record `session_part` rows and what a real provider's `data` holds |
| OpenCode's `/new` | In an open Chat on a conversation with a title, run `/new` and Send from Chat. Send a prompt in the terminal, and Send from Chat before and after the new conversation gets its title | Chat still shows the conversation it started with. Every Send sends nothing and says why, and the terminal's conversations gain no message from Chat. Record the raw title at each step, and whether a real title model leaves `OpenCode` for long |
| OpenCode's list | Pick another conversation in OpenCode's list, Send from Chat, then pick the first one back and Send again | The first Send names the other conversation's title and sends nothing. The second lands in the conversation Chat shows. Check the conversation's title in Chat equals the one the store holds on this version, since a title that reads differently refuses every Send |
| OpenCode's other database | Start OpenCode from New Agent with `OPENCODE_DB` set only in its shell rc, on a Host that also has the default database. Open Chat, then Send from Chat | Chat waits for the first message. Once the message goes unrecorded, **Conversation Not Found** names `OPENCODE_DB`. Record how long that takes |
| OpenCode's title off | Turn `terminal.title` off in OpenCode, then Send after `/new` and a prompt | The known limit: the title is empty, and the Send lands in the conversation on screen, not the one Chat shows |
| OpenCode unconfirmed | Start `opencode` by hand, then OpenCode 2.0 and 1.x from New Agent, then set a stale `heeler.session` label on one | **Can't Tell the Conversation**, each time, and the stale label is gone |
| Home folders | Start Codex and Grok Build with `CODEX_HOME` and `GROK_HOME` naming scratch folders, with other sessions in `~/.codex` and `~/.grok` | Chat reads from the scratch folders |
| Off until passed | Before adding a program to `HostCapabilities.confirmedLinuxCoreChatPrograms` on this box, or to `confirmedMacOSCoreChatPrograms` on a macOS core Host | It offers the terminal alone there |

A signed-in hc-lab run of 2026-11-03 (Debian 13, herdr-core 0.1.13), with codex-cli 0.165.0 and Grok Build 1.0.70 signed in by device code and OpenCode 2.2.2 on the owner's endpoint, in a debug build with every program in `confirmedLinuxCoreChatPrograms`, passed Codex without the daemon, Codex by default, A second default Codex, OpenCode 2.x, OpenCode's `/new`, and Off until passed on the candidate's own build. Codex's and Grok Build's `/new` ran as the rows above now read, except that no Send from Chat was tried after Codex's `/new`, where the first message showed a turn. Codex's held rollout's `session_meta` names a root thread, and a signed-in one also carries `creator_account_id` and `creator_user_id`, which a fixture must drop. The shared daemon was the box's 0.160.0, which ended with the first `/quit`; later in the run it updated itself to 0.166.0, and the restarted daemon outlived `/quit`. Its control socket `~/.codex/app-server-control/app-server-control.sock` is a symlink into `/tmp/codex-daemon-<uid>/`. Grok Build bound, its `pid_start` equal to field 22, but a Chat opened before the first message stayed on **Can't Tell the Conversation** until **Check Again**: the core's first `idle` came 0.18 s before Grok wrote its `active_sessions.json` row, and nothing checked again. OpenCode 2.2.2 left `session_part` empty with a real provider and kept the reply in `session_message`'s `data.content`, and a title replaced `OpenCode` about 2.5 s after the prompt. OpenCode's list, OpenCode's other database, OpenCode's title off, OpenCode unconfirmed and Home folders were not run there.

### Chat on a Mac

On a Mac Host with signed-in harnesses and the Host Helper installed as a LaunchAgent. Temporarily turn on each program in `HostCapabilities.confirmedMacOSCoreChatPrograms` that has not passed yet. A program that passes joins that list; Linux keeps its own, `confirmedLinuxCoreChatPrograms`. Record each result as a versioned observation in `docs/agents/herdr-compatibility.md`.

The run of 2026-11-02, on macOS 27.0.1 with herdr-core 0.1.13, Claude Code 2.1.316, codex-cli 0.165.0, Grok Build 1.0.70, Pi 1.4.0 and Oh My Pi 18.12.3, passed the Claude Code, SIP on, Codex, Pi and Grok Build rows, Oh My Pi with the extension, and Moved on under zsh ([herdr compatibility](../agents/herdr-compatibility.md)). OpenCode 2.0.32 from New Agent could only be chosen and 2.1 or later was not run, so it stays off on macOS. It stays in `macOSExactCoreChatPrograms`, since no read failed and Heeler's plugin label bound it exactly in the same run.

| Check | Do | Expect |
| --- | --- | --- |
| Claude Code | Open Chat on a `claude` at its prompt, from zsh and from New Agent | It follows that conversation. `sessions/<pid>.json`'s `procStart` equals `TZ=UTC LC_ALL=C ps -o lstart= -p <pid>`. Update ADR 0034's Unverified list. Read that file by name and never a `.key` file |
| SIP on | Run `csrutil status`, then read a zsh Terminal's `HC_SCOPE` through Chat with a Claude Code under it | SIP on: zsh's variables read as withheld and Chat still binds. The VM only ran with SIP off |
| Codex | `codex --no-daemon`, before and after the first message. Then plain `codex` | Can't tell, then it binds. Plain `codex` shows only the reopen message and no list |
| Pi | Start Pi with the Helper's extension, and take a reply | It binds through `heeler.session`, whose `start` equals the same read. The VM's Pi never finished a reply |
| Grok Build | Start `grok`, then read `active_sessions.json` | It binds. `pid_start` divided by a million is the second of that read. The VM saw one sample |
| OpenCode, Oh My Pi | OpenCode 2.1 or later from New Agent. Oh My Pi before and after the first message, with the extension and without it | OpenCode binds. Oh My Pi with the extension shows **No Messages Yet** until the first reply, without it can't tell, and then binds |
| Moved on | After Use This Conversation on any Agent, exit it and start another program in the same Terminal, then check Chat | The choice is dropped, and no banner stays. Under a shell with withheld variables too |
| Any read that failed | Note which row above could not bind | That program shows **Can't Tell the Conversation** and **Choose a Conversation**. Take it out of `HostCapabilities.macOSExactCoreChatPrograms` and note why |

### Choosing a conversation

The owner's checks on hc-lab with a signed-in harness, in a debug build with the
program's Chat turned on. Take zoomed Simulator screenshots of the list and of a
conversation before choosing, in light and dark, and attach them to the run's notes.

| Check | What to do | What to check |
| --- | --- | --- |
| OpenCode by hand | Start `opencode` by hand, send a prompt, open Chat, tap **Choose a Conversation** | The list holds the store's newest conversations in that directory, and any Status child. Nothing shows as bound and a Send from Chat sends nothing until you confirm. Record the process's open files |
| Grok Build's `/new` | In an open Chat, run `/new`, then choose | The list holds the session the process holds open and the folder's newest, and `s0`-style Status keys are not listed. Record each row |
| Read first | Open each kind of candidate | Its conversation shows, and **Use This Conversation** is only offered on one that reads |
| One label | Confirm one, then read the Terminal's labels with `terminal.get` through `scripts/fixtures/herdr-core-rpc.py` for your session | `heeler.chat` holds the session, pid and process start, equal to field 22 of `/proc/<pid>/stat` |
| Second device | Open the same Agent's Chat on a second Simulator | It shows the same conversation. With Chat open there, confirm on the first and clear on the box: it follows both, with no Retry |
| Process change | Quit the program and start it again in that Terminal | Chat says it cannot tell and the label is gone |
| Session switch | On a Pi with the extension, confirm from before it wrote, then run `/new` | The session label wins and `heeler.chat` is gone |
| Send guard | Choose the conversation on screen, Send from Chat and let that turn end. Switch the program to another session inside it, Send from Chat again and let that turn end | After the first Send's turn ends the pick stays. Within a few seconds of the second turn's end, Chat says it cannot tell in place of the conversation, with none of its messages left, and the label is gone. A turn that ends in `error` ends no turn, so the pick stays until a later turn ends. The bubbles of Sends made after the switch still read **Sent. It hasn't appeared in the conversation yet.**, since they landed in the other session. Grok Build refuses the second Send (see the next row), so the drop shows only on another program |
| The in-process limit | On a Pi without the extension, confirm, then run `/new` in the terminal | Chat keeps the old conversation until a Send from Chat fails the guard, as the guide says. Record that OpenCode's title and Grok Build's screen check refuse the Send instead, so neither drops the pick after `/new` |
| Codex by default | Plain `codex` on the shared daemon | No list, only `codex resume --no-daemon` |
| Codex behind a wrapper | A second default `codex` on that daemon, from a Template and from the desktop app under fish | No list, only `codex resume --no-daemon`. The same with `--no-daemon` on the Template's line says it can't tell, and does not ask to reopen |
| Herdr TUI | Any Chat on a Herdr TUI Host | No list, whatever it says |

A Mac run of 2026-11-02 with OpenCode 2.0.32 and Pi 1.4.0 passed OpenCode by hand, One label, Process change, Session switch, Send guard, The in-process limit and Codex by default ([herdr compatibility](../agents/herdr-compatibility.md)). Read first passed only in part: both of OpenCode's store rows and the one Pi transcript opened showed their conversation with **Use This Conversation**, but no candidate failed to read and none was held open or a Status child, so withholding the offer on one that doesn't read was not exercised. For Session switch, the extension labels Pi as it starts, so the pick from before it wrote came after clearing that label by hand with `terminal.label`. A second device, Grok Build's `/new`, a wrapper and Herdr TUI were not run there.

A signed-in hc-lab run of 2026-11-03 (Debian 13, herdr-core 0.1.13) with codex-cli 0.165.0 `--no-daemon` and Grok Build 1.0.70, in a debug build with every program in `confirmedLinuxCoreChatPrograms`, passed Grok Build's `/new` (two conversations open in the program and one in the directory, no `s0`-style row, in zoomed light and dark screenshots), One label for both (Codex's names its native process, not the `node` launcher, with the start equal to field 22), Send guard on Codex, and Codex by default. Send guard ran as its row reads: the picked conversation stayed after a Chat Send's turn ended. After `/new`, the next Send's turn ended in `error` (the model was at capacity), so the pick stayed. The turn after that ended `done`, and 6 s later the label was gone and Chat said it can't tell. On Grok Build the pick, and its staying after a Send, passed too, but after `/new` its screen check refused the Send twice, seven minutes apart, so the drop could not happen there. Read first passed only in part: every candidate opened read and offered **Use This Conversation**, and none failed to read. OpenCode by hand, Second device, Process change, Session switch, Codex behind a wrapper and Herdr TUI were not run there, and The in-process limit was not run as written, with no Pi in that stage.

## Pi and Oh My Pi Chat

Each program's Chat on a Linux core Host stays off until its check here passes: add it
to `HostCapabilities.confirmedLinuxCoreChatPrograms` only then. Both are on for macOS
since the [Mac run](#chat-on-a-mac), and for Linux since the signed-in hc-lab run of
2026-11-03. Until a program passes, use a debug build
with that set widened for the run, and do not commit that edit. Sign Pi and Oh My Pi in
on hc-lab, and install the Host Helper first unless a step says otherwise. Record each
program's version and result as a versioned observation in
[herdr compatibility](../agents/herdr-compatibility.md), keep what differs from the
recordings beside `Tests/HeelerTests/ChatFixtures/host-evidence`, and update the
Unverified list in [ADR 0034](../adr/0034-herdr-core-chat-binds-sessions-from-host-evidence.md).

| Check | What to do | What to check |
| --- | --- | --- |
| Started by Heeler | Start Pi, then Oh My Pi, from New Agent, send one message, open Chat | The conversation shows. The Terminal has the label `heeler.session` with `file`, `pid` and `start` |
| `hc run` | Start each with `hc run`, send one message, open Chat | The same conversation binding, from the extension alone. No launch label |
| Template | Start each from a Template, send one message, open Chat | The same |
| `/new` | In an open Chat, run `/new` in the terminal and send one message | The new conversation shows by the next check |
| Own folders | Start Pi with `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` naming scratch folders, Oh My Pi with `OMP_PROFILE` and with `PI_CONFIG_DIR`, while the default folders hold other sessions | Chat reads from the Agent's folder, not the default one |
| Pi without the extension | Remove the Helper, start Pi from New Agent, open Chat, then send one message from the terminal | Chat waits, then shows the conversation. Now run `/new`: it stays on the old conversation |
| Pi by hand, no extension | With the Helper still removed, start `pi` from a shell and from a Template | **Can't Tell the Conversation**, and the message names the Host Helper. Nothing binds from the folder |
| Oh My Pi without the extension | With the Helper still removed, start `omp` and open Chat before the first message | **Can't Tell the Conversation**. Send one message: it binds only once `/proc/<pid>/fd` holds the file `terminal-sessions/pts-<n>` names. Record how long that took. **Known defect**, seen once with Oh My Pi 18.13.3 on herdr-core 0.1.13: once the file was held, Chat stayed on **Can't Tell the Conversation** until **Check Again**, four minutes later. In the same run, with its title model returning no title, Oh My Pi never opened the file in 2.5 minutes, so the open seems to follow a title (each way seen once). Record whether a title came back |
| Reused terminal name | Exit that `omp` and leave its breadcrumb. Start `omp` again on the same terminal name, before a message | Nothing binds to the earlier session |
| Security scan | With an OAuth account, run Oh My Pi's security scan, then a check | Record whether the breadcrumb goes back to the session. Chat must not show the scan's file as the conversation |
| Stale label | Set `heeler.session` with `terminal.label`, holding another pid, then open Chat | The label is gone and Chat does not show its session |
| One read per check | With the Host's sshd logging exec requests, open Chat on an idle Agent | One exec and at most one read per check, and nothing while idle. No `HERDR_*` variable changes the result |

A signed-in hc-lab run of 2026-11-03 (Debian 13, herdr-core 0.1.13, Pi 1.4.0 and Oh My Pi 18.13.3 on bun 1.4.4 against the owner's endpoint, Host Helper 0.5.3, a debug build with every program in `confirmedLinuxCoreChatPrograms`) passed Started by Heeler, `hc run` and `/new` for both programs, Template for Oh My Pi, whose label named its own pid and not its `sh -c` parent's, Pi without the extension, Pi by hand with no extension (started with `hc run` in place of a shell, and from a Template), and Reused terminal name. Pi from a Template has no saved evidence of its label or its reply, so that row is still open for Pi. Oh My Pi without the extension held its file 8.6 s after the first message, yet Chat stayed on **Can't Tell the Conversation** until **Check Again**, four minutes later. In an earlier stage of the same run, without the extension and with its title model returning no title, Oh My Pi never opened its file in 2.5 minutes, so the open seems to follow a title; each way was seen once. After Pi without the extension ran `/new`, a Send from Chat went into the new session, and its bubble still read **Sent. It hasn't appeared in the conversation yet.** six minutes later. Own folders, Security scan, Stale label and One read per check were not run.

## Chat typing

Use the same box and Claude Code as [Chat evidence](#chat-evidence). The tests read
paints a fixture core made of replayed screens, never a live Agent's, so correct
[herdr compatibility](../agents/herdr-compatibility.md) with whatever differs. Record
Claude Code's version, and keep one paint from an observing attach of its prompt and
one of its permission dialog beside the fixtures in
`Tests/HeelerTests/ChatFixtures/screens/core-paint`.

| Check | What to do | What to check |
| --- | --- | --- |
| Send | Send a multi-line message from Chat to an idle Agent | It reaches the Agent as one message and the turn starts. The Composer shows it delivered |
| A held Send | Type a draft in the terminal's input, then Send from Chat | Nothing is sent, the draft stays, and the notice says the input box already has text |
| Stop | Stop a running turn from Chat | The turn stops on one tap. Nothing is left in the input |
| Template's stop key | Start a Template with a `stop` key, Claude Code as its command, then Stop from Chat during a turn | That key reaches the program |
| Blocked card | Make Claude Code ask for permission, then answer from the card | The dialog closes with that answer and the turn goes on. The Composer returns |
| Dialog gone | Open the card, answer the dialog in the terminal, then tap the stale card at once | Nothing more reaches the Agent |
| Second viewer's size | View the Terminal from a second client at another size, then Send and Stop from Chat | The second client's size and the Terminal's stay as they were, with no `size` event |
| Moved conversation | Run `/clear` in the terminal, then Send from Chat before the next status change | Nothing is sent, the draft stays, and Chat moves to the new conversation |
| Exit race | Run the Composer's exit race from Chat, on bash | No file. The draft stays and the notice says **no longer in the terminal** |

On hc-lab on 2026-11-02 (Debian 13, herdr-core 0.1.13), Template's stop key passed with Claude Code 2.1.316 against a fake model as the Template's command and `shift+tab` as its key: Claude Code changed its permission mode and went on working, so the Template's key took the place of its own. A Template that wrapped Claude Code in `script` was not listed as an Agent and had no Chat, so its key could not be sent from Chat.

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

## Composer Stop

`HerdrCoreComposerStopTests` hold what Heeler sends against a scripted core: one
`terminal.interrupt` with `timeout` 2, then a `terminal.get`. These steps need the
programs themselves, and show the read through what the app does next. Record each
version and result beside the check it answers.

| Check | What to do | What to check |
| --- | --- | --- |
| Pi keeps running | Give Pi a long prompt, then tap **Stop** | The turn stops, Pi stays the Agent, and Send comes back |
| Codex exits | Run Codex where the key ends it, or a stand-in that reports working and exits on Esc, then tap **Stop** | The Agent leaves the list about when the program goes, and no Stop shows on that Terminal |
| Never reports | Run a program that has never reported in a core Terminal, as a copy of `cat` named `claude` | It reads **Unknown**, so the Composer shows no Stop, since Stop needs Working. From a test client, `terminal.interrupt` with `timeout` 2 answers `unknown` after the two seconds and presses Ctrl+C, and `terminal.get` then shows whether it still runs |
| Ignores the key | Run a stand-in that reports working and ignores Esc, then tap **Stop** | The spinner lasts about three seconds, then the notice says **still shows Working** and **Stop** works again. The stand-in stays the Agent |
| Template | Start a Template with a `stop` key, wait for it to report working, then tap **Stop** | The program receives the Template's stop key |
| Grok Build | Give Grok Build a long prompt | The Composer keeps **Send** on a blank draft and offers no Stop |
| Shell behind | Exit an Agent under the desktop app's wrapper, so its shell continues in the Terminal | No Stop on that Terminal, although the core would press Esc there |

On hc-lab on 2026-11-02 (Debian 13, herdr-core 0.1.13), Template passed: a stand-in started from a Template with `stop: ctrl+g` read byte `07` when **Stop** was tapped.

## New Agent and New Terminal

Use three throwaway accounts on hc-lab whose login shells are bash, zsh and fish, and
in each put a harmless stub on `PATH` only through the shell's own startup file
(`~/.bashrc`, `~/.zshrc`, `~/.config/fish/config.fish`), with a marker variable beside
it. Never sign in to a harness: an Agent that stops at its sign-in has already shown
its flags. Read each launch with `terminal.get` through
`scripts/fixtures/herdr-core-rpc.py`.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| Startup files | Open **New Agent** on each account, with a stub named as an agent | That agent is listed, and an agent only on the SSH exec's `PATH` is not. `argv` reads the shell replacing itself, fish's own form on fish, and `env` holds no `PATH` |
| The Agent's environment | Start the stub, and print the marker in it | The startup file's marker and `PATH`. `pid` and `foreground.pid` are the same, with no shell left behind |
| OpenCode 1.19.5 | Install it, then start it | `argv` has no `-s`, and no `heeler.launch-session` label |
| OpenCode 2.2.2 | Install it, then start it | `argv` has `-s ses_…`, and the label `heeler.launch-session` holds the same id |
| zsh with no startup files | Remove `~/.zshrc` on the zsh account, then start an Agent | It waits at zsh's new-user wizard. Answering it in the terminal lets the Agent start |
| Shell from the core | A blank shell field for the account in `/etc/passwd`, and a core started with `SHELL` set | `argv` uses the core's `SHELL`. With it unset too, **New Agent** says the Host does not report your login shell, and nothing starts |
| Derived Workspace | **New Terminal** in a directory's Workspace, then `cd` elsewhere in a Terminal there and start another | Both land in that card, both with the Workspace's own directory, and no `herdr.*` label |
| Browsing | **Browse Directory…** in **New Agent** and in **New Terminal** | Remote folders list, and the launch lands in a card named for the one chosen |
| Mac with the desktop app | On a Mac running the Herdr desktop app, **New Terminal** in one of its spaces | It shows in a new tab of that space in the window, and `terminal.get` has `herdr.space` and a new `herdr.tab`. Never `doc.set` on this core |
| No answer | Cut the route just after tapping **Start** | Heeler says the Host did not confirm the launch, and `terminal.list` shows at most one new Terminal |
| Template with a slow first report | A file in `~/.config/herdr-core/templates/` with a body, whose `command` is a harmless stub that sends its first OSC 7501 report after about 28 seconds and keeps reading its input, then pick it under **Templates** in **New Agent** and start it | **New Agent** shows it starting for the whole wait of about 33 seconds, then opens it as an Agent with the Template's body typed. `terminal.get` has `argv` reading `sh -c <command>`, its `template`, `submit` and `stop`, and no `heeler.launch-session` label, and `terminal.list` shows one new Terminal. A stub that reports at 30 seconds or later still opens, but with no body typed |

On hc-lab on 2026-11-02 (Debian 13, herdr-core 0.1.13), Template with a slow first report passed with stubs reporting at 28 seconds, which opened with its body typed after **New Agent** showed it starting for the whole wait, and at 31 seconds, which opened with no body typed.

## Close

With a kept Terminal and two pinned Agents, from inert programs if you like. `terminal.get` still answers for a closed Terminal.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| A kept Terminal | Swipe its row, **Close**, then confirm | The row goes and stays gone. `terminal.get` reads `finished` with reason `killed`, and it does not come back as a shell |
| Between programs | `kill -9` a kept Terminal's program, then close it while it reads **Restarting** | The row goes, with no restart |
| An Agent's row | Close a pinned Agent from its row | Its Pin is gone. The other Agent's Pin stays |
| A Tab with two Terminals in a desktop space | Close one, then the other | The first closes as a Pane and the second as the Tab. No shell stays in the desktop app's layout |
| Agent detail, Shell Terminal | **Close Agent**, **Close Terminal** in the More menu | Back at the list, with the same `terminal.get` |
| No answer | Cut the route just after confirming | Heeler says the Host did not confirm the close, and `terminal.kill` is not sent again after the route returns |

## Worktrees

With a throwaway git repository on hc-lab, a Workspace in it and an inert program as the Agent. Never sign in to a harness. Read git with plain `git` in a login shell on the box.

| Check | How to get there | Heeler shows |
| --- | --- | --- |
| New branch | **New Agent** in the repository's Workspace, **Start in a new worktree**, the branch `lab/new`, which does not exist | The checkout is at `~/.herdr/worktrees/<repository>/lab-new`, on `lab/new` from the Workspace's HEAD, in a new Workspace with the Agent running in it. `terminal.get` has `herdr.space` and `herdr.tab` |
| Existing branch | The same with a branch `git branch` already lists | That branch is checked out, and no new branch appears |
| Remove | **Worktree Details** in the Agent's More menu, **Remove Worktree**, with a second Terminal in that Workspace | Both Terminals read `finished` with reason `killed`, no shell is left in the removed checkout (`pgrep -a -f` on its path finds nothing), the folder is gone, and `git branch` still lists the branch |
| Changes | `touch` a file in a checkout, then remove it | The confirmation says the uncommitted changes will be lost, and removal goes through |
| Submodules | A checkout with a checked-out submodule, then remove it | The confirmation names submodules, and removal goes through |
| A Terminal that will not end | Cut the route just after confirming | Heeler says the checkout was not removed, and it is still there after the route returns. A second try finishes it |
| Native Windows | A native Windows core Host | **New Agent** offers no worktree |
| Mac with the desktop app | On a Mac running the Herdr desktop app, start a Worktree from Heeler | It shows as a space in the window at the same path the app's worktree mod uses for that branch |

## Agent Row Layout

Open **Settings**, then **Agent List Fields**, and the Host.

| Check | What to do | What to check |
| --- | --- | --- |
| Starting rows | Open a Host you have never edited | **Heeler's fields**, Row 1 `terminal_title_stripped`, Row 2 `directory`, Row 3 empty. No **Sync from plugin**, and no word of Sync or the plugin on the page |
| Labels | Label a Terminal on the box, then add a field to a row | The label is offered under **Terminal labels**, and the Agents tab shows its value. No `$` field and no `state_text` is offered |
| Right side | Add a field to a row's right side | `status_badge` and `changes` are offered there and not on the left, and the sheet says **right side** with no word of herdr |
| Apply to All Hosts | With a second Host, tap **Apply to All Hosts** on the core Host's page | The other Host's rows take these fields. A label field shows nothing on a Host whose Agents lack that label. A Herdr TUI Host's Live Activity keeps showing its other fields |
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

An hc-lab run of 2026-11-02 (Debian 13, herdr-core 0.1.13, inert programs and Claude Code 2.1.316 against a fake model, the app on an iOS 26.5 Simulator) passed Pin, Removed while connected, Removed while away, Core restart and Wiped core, the last on a throwaway session with another Host's Pins kept. Herdr TUI beside it was not run.

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
| Link recovery | With an Agent detail open and a draft typed, block the route to the Host, then restore it | The screen and draft stay, the title reads **Reconnecting…**, Send and keys are refused, and input comes back once the Agent's row does |

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
| New Workspace on that Mac | New Terminal, **New Workspace**, pick a folder, **Open** | A new space appears in the window, unnamed and last, and reads the same in both. `doc.get` shows only the app's own writes |
| Rename on that Mac, a debug build launched with `--herdr-app-rename` | With the app running: type a name in New Workspace, then **Rename Workspace** from a space's Agent | The typed name lands once after the app adopts the space, and Rename lands in the window and in the Console. With the app quit, the name field and Rename are gone. Turn `HerdrAppControl.isRenameConfirmed` on only when all of this holds over SSH |

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
| Node.js gone under a running Helper | Rename the Node.js executable the unit names and leave the Helper running, then check the Host and read Usage | The row reads **Node.js Moved** with **Repair**, Usage asks for the repair, and notifications still arrive. Restore a Node.js and tap **Repair**: the row reads the version, and Usage reads again once the core is running |
| Damage | Change a byte in `app/main.js`, then check the Host | The row reads **Damaged**, and **Repair** puts the file back and keeps `notifications.json` |
| Extensions listed | Read the sheet before installing | It lists `heeler-session.js` in `~/.pi/agent/extensions`, `~/.omp/agent/extensions` and `~/.omp/profiles/work/agent/extensions`, and those are the files on the Host afterwards. `installed.json` names each one, and each folder the install created |
| Pi label | Start Pi in a core Terminal, then `/new` | The Terminal's `heeler.session` label is JSON naming the session id, its file, Pi's pid and `start`, the process's `/proc/<pid>/stat` field 22. `/new` rewrites it with the new session |
| Oh My Pi label | Start `omp` and `omp --profile work` in core Terminals, then `/new` in one | Each carries the same label, with a session file under its own profile. `/new` rewrites it |
| Inert outside | Start the same programs outside herdr-core, with no `HC_TERMINAL_ID` | They behave as before, and nothing connects to the core's socket |
| Slow socket | Start Pi in a core Terminal with `HC_TERMINAL_SOCKET` pointing at a socket that accepts and never answers | Pi starts as usual, with no delay and no message on screen |
| Pi status | Run Pi 1.0.4 and Pi 1.4.0 in core Terminals through a prompt | 1.0.4 reports idle, working and done through the extension, with an intact screen during the run, which the spike could not test without a model. 1.4.0 reports for itself, and `app=pi` reports do not double |
| New profile | Make another Oh My Pi profile, then check the Host | The row still reads the version, and the sheet offers **Repair**, which adds that profile's file and touches no other file of the Helper |
| Remove | Tap **Remove** and confirm | The unit is gone and inactive, the Helper directory and every folder the install created are gone, no `heeler-session.js` is left, and the saved listing matches again. Linger stays on, and the Grok Build setting is untouched. For an applied OpenCode edit, see [OpenCode edit](#opencode-edit) |

Every step must leave the core as it found it: the Helper only ever follows a core,
and never starts one. The extensions only ever write the one label on their own
Terminal.

An hc-lab run of 2026-11-02 (Debian 13, systemd 257 with no polkitd, herdr-core 0.1.13, Host Helper 0.5.3 on a throwaway account with its own Node.js v22.23.3, Pi 1.4.0 and Oh My Pi 18.13.3 against a fake model) passed Install, Privacy, Linger, Log out, Restart, Node.js gone under a running Helper, Damage, Extensions listed, Pi label, Oh My Pi label with the `work` profile and `/new`, Inert outside, Slow socket and Remove. Install's sheet was read only in part: 53 of the 62 files on the Host, each of them there. With no polkitd, **Turn On Linger** showed the Host's refusal and the `sudo loginctl enable-linger` line at the bottom of the sheet, and the sheet kept **Linger Off** after an administrator turned linger on, until the Host's detail was opened again. Node.js moved ended `failed` with result `exit-code`, not `start-limit-hit`, after "Start request repeated too quickly", and **Repair** brought it back. New profile added that profile's file, but **Repair** also rewrote the unit and the other extension files with the same bytes and restarted the Helper. Remove's listing differed from the saved one only by the sessions, caches and logs Pi and Oh My Pi had added, and the profile made for New profile. Pi status was not run, with no Pi 1.0.4 on the box. A signed-in run of 2026-11-03 installed and removed the same Helper on the box's own account: an install over a link that dropped failed with "The incomplete temporary file could not be removed safely" and left a staging folder, which the next install cleaned up, and after the removal Pi's own cache of the extension stayed in `/tmp/jiti`.

### The Helper on macOS

This one needs a Mac, not hc-lab: the Mac Host you have named for the run, with
Node.js and no earlier Helper. Before installing, save
`cd ~; find Library/LaunchAgents "Library/Application Support/heeler" .pi .omp -print 2>/dev/null | sort`,
and read the steps in `launchctl print user/$(id -u)/dev.bybee.heeler.host-helper`
as the agent.

| Step | What to do | What must happen |
| --- | --- | --- |
| Install | Tap **Host Helper**, read the sheet, and tap **Install** | The sheet has no linger row, and it lists every file, the property list and `helper.log` included, and those are the files on the Host. `state = running` with the absolute Node.js path in `program`, `domain = user/<uid>` |
| Privacy | `ls -la` the Helper directory, its `app` folder and the property list | Directories `0700`, files `0600`, the log still `0600` after the agent has written to it |
| Log out | End every SSH session, and log out of the desktop if someone is logged in. Wait a minute, and SSH back | The same `pid`, and `runs` unchanged |
| Kill | `kill -9` the agent's `pid` | A new `pid` and a higher `runs`, and the row still reads the version |
| Node.js moved | Rename the Node.js executable the property list names, kill the agent, and check the Host | `state = spawn scheduled`, `last exit code = 78: EX_CONFIG`, and the row reads **Service Failed** or **Node.js Missing**. Restore Node.js and tap **Repair**: it runs again |
| Node.js gone under a running Helper | Rename the Node.js executable the property list names and leave the agent running, then check the Host and read Usage | `launchctl print` keeps `state = running` and the pid, the row reads **Node.js Moved** with **Repair**, Usage asks for the repair, and notifications still arrive. Restore a Node.js and tap **Repair**: the row reads the version, and Usage reads again once the core is running |
| Restart | Restart the Mac, wait for sshd, and read the agent before opening Heeler | Write down whether anything loaded it (in a VM of macOS 26.5, nothing did). Open the Host's detail: the agent runs, without an install |
| Background notice | Read the desktop's notifications and Login Items | Write down what it says, and what turning the entry off does (not tried yet) |
| Usage Limits | With Claude Code signed in with an account of the Mac's own, turn on Usage Limits for the Host | They read that they need your own login on this Mac, with Token Usage still counting |
| Remove | Tap **Remove** and confirm | `launchctl print` answers 113, no agent process is left, and the saved listing matches again |

A run of 2026-11-02 on macOS 27.0.1 passed Install, Privacy, Kill, Usage Limits and Remove ([herdr compatibility](../agents/herdr-compatibility.md)). Its Usage Limits read ran from the SSH exec, not from the agent. The other steps were not run there.

### The Helper and the core

Use a unique non-default session `<s>` of your own, plus a second one `<s2>` for the
last step, and start and stop nothing else. With no device registered from the app, name it by hand, in the Helper directory:
`printf '{"v":1,"devices":[{"session":"<s>"}]}' >
~/.local/share/heeler/host-helper/notifications.json`. Remove the file when done.

| Step | What to do | What must happen |
| --- | --- | --- |
| No core | `HC_SESSION=<s> ~/.local/bin/herdr-core server stop` if it runs, then `systemctl --user restart heeler-host-helper` | `systemctl --user list-units 'hc-serve-*'` shows no new unit, however long you wait. `journalctl --user -u heeler-host-helper` reads `core session "<s>": waiting for a core at <socket>` once |
| Core starts | From the user's login shell, `HC_SESSION=<s> ~/.local/bin/herdr-core server start`, and do not touch the Helper | Within seconds the journal reads `connected to core pid <pid>`, the pid `<s>`'s `server.status` reports. The unit's main PID has not changed |
| Core restarts | `kill -9` that pid from `<s>`'s `server.status`, then start `<s>` again the same way | The journal reads `connection to core pid <pid> ended`, then `connected` with the new pid |
| Other sessions | `HC_SESSION=<s2> ~/.local/bin/herdr-core server start`, which the file does not name and no Host's Usage asked about. Stop `<s2>` the same way when done | The journal never mentions `<s2>`, and `ss -xp` shows the Helper connected only to `<s>`'s socket |

The hc-lab run of 2026-11-02 above passed all four steps.

### Agent Notifications

Point the Helper at a fake relay: a small HTTP server on the Host that logs each `POST
/push` body and answers `200`. Register a device from the app first, then set `relay_url`
in the Helper directory's `notify.json` to `http://127.0.0.1:<port>`, and optionally
`debounce_ms`. A real device needs the real relay for the steps that say so. Never sign in
to a harness for this: use a throwaway program that reports status, or the mock API from
[Program Status](#program-status).

| Step | What to do | What must happen |
| --- | --- | --- |
| Turn on | In **Settings > Notifications**, turn the Host on | `notifications.json` in the Helper directory holds one entry, whose `session` is the core session (`default` when unnamed). `~/.config/herdr/plugins` has no change |
| First sight | Restart the Helper with an Agent already Blocked | No push: what a core already showed is not announced |
| Blocked | Make an Agent ask for permission, and let it stay | One push per registered device after the debounce. Decrypting with the device's key gives `blocked` |
| Flap | Make it leave Blocked within the debounce | No push |
| Error | Make an Agent report error | One push, under the Blocked switch. The device reads **Error** |
| Done | Let an Agent finish a turn with no device on it | One push per registered device with Done on |
| Per-device Done | On one of two devices, keep the Agent open until the turn ends | `seen-<key id>.json` for that device has the turn. The other device gets Done, this one does not |
| No Agent | Run `sleep` in a Terminal, then exit a program back to its shell | No push for either |
| Restart | Stop the Helper during a turn, start it after the turn ends | One Done on start, not two after another restart |
| Heeler killed (real relay) | Kill Heeler on a real device, make an Agent Blocked | The notification arrives, and a tap opens that Agent's detail |
| Off | Turn the Host off | The entry and `seen-<key id>.json` are both gone from the Helper directory, and no push follows |
| Remove | With a mark present, remove the connected Host | The same. Removing it while disconnected reads that notifications are left behind |
| Helper states | Stop the service, then hide Node.js from it | **Settings > Notifications** names **Service Failed**, then **Node.js Missing** |
| Native Windows | Open **Settings > Notifications** with a native Windows core Host | It reads that Agent Notifications, in-app banners included, and Live Activity come with the Host Helper and are not available there yet |

The hc-lab run of 2026-11-02 above, with a fake relay on the box and one Simulator, passed Turn on, Blocked, Flap, Error, Done, No Agent, Restart, Off and Native Windows. The app's **Custom Push Relay** setting in **Settings > Notifications** wrote `relay_url` into `notify.json` at registration, so the file needed no edit by hand. Envelopes were not decrypted, so the word inside was not checked. First sight held for a core the Helper had not seen and for a Blocked it had already sent, but a Blocked reached while the Helper was stopped, on a core it knew, was sent once at start, as Restart expects for Done. Per-device Done was run on one device only, and Helper states reached **Service Failed** but not **Node.js Missing**, since a Node.js stayed where the app looks. Heeler killed and Remove were not run.

### Banners and Live Activity

Keep the fake relay for the first table. `activity_debounce_ms` in `notify.json` sets the Live Activity debounce, 1500 by default. A fake relay's log shows `kind: liveactivity` bodies beside the alert bodies, and the counts in them are plaintext.

| Step | What to do | What must happen |
| --- | --- | --- |
| Blocked banner | With Heeler open on the Console and this device registered, make an Agent ask for permission | A banner after about three seconds, reading **Blocked — waiting for input** |
| Error banner | Make an Agent report error | A banner reading **Error**. With the Blocked switch's entry flag off in `notifications.json` and the app refreshed, none |
| Done banner | Let an Agent finish a turn while you are on the Console | A banner reading **Done**. Repeat with the Agent open: none |
| No registration | Turn the Host off in **Settings > Notifications**, repeat the steps above | No banners, and any activity for the Host ends |
| No Helper | Remove the Helper with the Host still known | No banners and no **Live Activity** switch |
| Token | Turn on **Live Activity** for the Host with an Agent Working | `live_activity.token` appears in this device's entry in the Helper directory. `~/.config/herdr/plugins` has no change |
| Update | Move an Agent from Working to Blocked with Heeler suspended | One `update` body with priority 10 and `blocked` 1. Decrypting the envelope with the device's key gives the Agent as `blocked` |
| Error count | Make an Agent report error with Heeler suspended | `blocked` counts it, the body has no other count, and its entry reads `blocked`. Moving it from Blocked to Error sends nothing |
| Per-device Done | With two devices registered, open the Agent on one until its turn ends | The other device's body counts `done` 1, this one's `done` 0 |
| End | Let the last Agent go idle with no Done left for the device | One `end` body with zero counts and a `dismissal_date`, and none after it |
| Dismissed (real relay) | Dismiss the activity on a real device, change an Agent's status | The relay's 410 removes `live_activity` from the entry. Its `token`, `key` and `notify` stay |
| Older Helper | Register on Host Helper 0.4.0 | Notifications work, no **Live Activity** switch, and a note asks for a newer Helper |
| Suspended (real relay) | Start an activity on a real device, suspend Heeler, change statuses | The Lock Screen updates, then ends when nothing is left |

The hc-lab run of 2026-11-02 above passed the Blocked and Done banners, the Error banner with the Blocked switch on, No registration for banners, and Token. With a token registered and Heeler in the background, no Live Activity body reached the fake relay at all, so Update, Error count and End could not be seen; the cause was not found. No Helper was seen only in part, with no banner and the switch not read. The Error banner with the entry flag off, Per-device Done, Dismissed, Older Helper and Suspended were not run.

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
| Usage off | Turn **Usage** off in **Settings**, then back on, with a Usage widget installed | While off the tab and the Host's section are gone, and the widget says Usage is off. Back on, the figures return. The Helper stays installed throughout |
| Widget alone | Add a Usage widget. With the core stopped and no Helper, reopen Heeler and do not open Usage. Repeat on an unreachable Host, and on a native Windows Host if one is on hand | The widget says **Needs the Host Helper**, **Not connected**, and **Comes with the Host Helper, not available yet**, and keeps saying so after you force-quit Heeler and reopen it. None of them reads **Not read yet** |

`/proc/<pid>/environ` holds the environment the core started with, so a variable it set for itself later does not appear. A Windows Host's line is covered by unit tests, not this checklist.

The hc-lab run of 2026-11-02 above passed No Helper for the tab and the Host's section, Core's environment for the tab, Only named variables, Core restarts and Suggestions. Waiting read **Waiting for the core** in the Usage tab and "Could not read Usage. Check the Host connection and try again." in the Host's section, with no new core unit. The widget was not checked, and Limits, Update, Unreachable, Usage off and Widget alone were not run.
