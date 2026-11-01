# Connect herdr-core

Agents started by the Herdr desktop app belong to herdr-core, a server of their own. They do not appear in the Herdr TUI server, even when both run under the same SSH account, so each one is a Host of its own in Heeler. Heeler reads herdr-core 0.1.13, and 0.1.16 on native Windows. The app and the core have separate version numbers.

## Add a Host

1. In the Hosts tab, tap **+** and enter the SSH account and Route. Use Device Key, RSA Key, or Password authentication. For a Device Key, copy the form's public-key line into the Host's `~/.ssh/authorized_keys`. A Pairing Code always adds a Herdr TUI Host, so it is not the way to add this one.
2. Leave Session blank for `default`, or enter the desktop core's `HC_SESSION` name.
3. Save, and trust the Host's key. Heeler reads once what the machine runs, and that read starts nothing.
4. Confirm what it found:

   | Heeler found | You see |
   | --- | --- |
   | herdr-core | **Use herdr-core** |
   | Herdr TUI | **Use Herdr TUI** |
   | Both | Both choices. A Host is one kind: confirm one, then add the machine again for the other |
   | Neither | Both choices. The one you confirm then says how to set it up |

A session name the server refuses leaves the Host unconfirmed and says why. The checks run after you confirm. A Host keeps its kind, so a Host you added before stays what it is.

## Not running and Start

Heeler never starts a core by connecting or checking, so a mistyped session name reads **herdr-core is not running** rather than an empty, new core. While the core is not running, Heeler keeps trying to reconnect by itself, and the Host's checks run again when the core stops or comes back.

| Host reads | What to do |
| --- | --- |
| **herdr-core is not installed** | Install it on the SSH PATH or at `~/.local/bin/herdr-core`, or with its installer on native Windows, then check again |
| **herdr-core is not running**, nothing listening at a socket path | Start the core. Check the session name if you expected it running |
| **herdr-core is not running**, a socket file left behind | Start the core, or allow stream-local forwarding in the Host's SSH server. Heeler cannot tell these two apart from here |
| **The SSH server refuses socket forwarding** | Allow stream-local forwarding in the Host's SSH server |
| **herdr-core needs an update** | Run the update command it shows, then check again |
| **The herdr-core socket path is too long** | Use a shorter session name, or set a shorter socket in the core's config |

**Start herdr-core** appears under the checks on a Linux Host whose core is not running. It asks first, naming the session, the interactive login shell it starts through, and systemd linger, which it tries to turn on when it is off. The core then has the environment your own terminal has. If a core was already running by then, Heeler says so and that Start changed nothing. On macOS, Heeler says how to start the core yourself.

## Native Windows

Add a Windows machine as any other Host, over its OpenSSH server. Heeler looks for the core where its installer puts it, `%LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe`, and connects only once the core's named pipe exists. Each reconnect looks again, so a core you stopped stays stopped: the Host reads **herdr-core is not running** and keeps checking.

Heeler never starts a core on Windows. On that machine, in your desktop session, open PowerShell, not as administrator, and run the command the Host's checks show. For a session named `work` it reads:

```powershell
$env:HC_SESSION='work'; C:\Users\you\AppData\Local\Programs\herdr-core\herdr-core.exe server start
```

A session name there uses letters, digits, `-`, `_` and `.`, and does not start with `-`. Leave Session blank for `default`.

The Console lists the core's Agents and Terminals, each in a card named for its directory or its space. A space nobody named takes its repository's folder when `git` is on the PATH of an SSH session there, and its directory's otherwise. Open one for its Agent detail with Direct Input, or as a Shell Terminal, and close it from there.

Not offered there yet, whatever the Host reads: New Agent, New Terminal, New Workspace, images and files in the Composer, Send, Stop, Chat, Rename and Worktrees. Changes and Skills read as unavailable, and the Host Helper reads **Not Available**.

## Console

A core Host's Terminals follow the Herdr desktop app's organization when the core has one. Heeler reads it and never changes it.

- Each desktop space is a card under its own name, in the desktop app's order. A row reads **Tab “name”**, or **Tab N** for a tab with no name.
- A space that only a Terminal's label names follows the desktop app's spaces, named for the folder of its git checkout, or for its directory outside one.
- A Terminal started from another Terminal joins its parent's card, unless its own labels place it elsewhere.
- Every other Terminal goes in a card named for its launch directory.

A changed space, tab or label moves the rows within a moment, with no reconnect.

## Agents and status

A Terminal is an Agent while its foreground program is a known coding program, or any program but a shell that reports a status. Everything else stays in the Terminals tab. Quitting a harness back to its shell ends the Agent, whatever it last reported.

| Status | What it means |
| --- | --- |
| **Unknown** | The program has not reported yet |
| **Working**, **Idle** | What it reports. A program reporting done reads **Idle**, unless it shows **Done** |
| **Blocked** | It waits for you |
| **Error** | It reports an error, and sorts with **Blocked** |

The Agents tab sorts by status, with those waiting for you first, and within a status in the desktop app's order of spaces, tabs and panes. By Workspace takes its cards from the same order.

Done is per device. An Agent shows Done when it finished a turn this device was not showing and still reports idle or done. Opening the Agent clears it here, and so does having it open when the turn ends; your other devices keep showing it until you open it there. It leaves on its own when the Agent starts working again. A turn finishes when a program goes from Working to Done. A program not known to report done also finishes one by going from Working to Idle, while Claude Code, Codex, Pi and Oh My Pi do not, so a Codex release too old to report done never shows Done. Removing the Host, or the Host getting a different core, starts over.

Tap **Unknown** on an Agent's status line to see why it reads that way. Each program reports its status from a release on: Claude Code 2.1.295, Codex 0.163, OpenCode 2.1, Pi 1.1.0 (earlier releases report through the [Host Helper](#host-helper)) and Oh My Pi 18.8.7, so an older one stays Unknown. No such release is known for Grok Build or for a program Heeler does not recognize. A Terminal that has reported but holds no state reads as not having reported a state yet. Heeler never works out a status from the screen.

**Grok Build's status.** Grok Build's automatic check leaves its status off where its query cannot run, such as under a core started with `TMUX` set. On a Grok Build Agent with no status, that same sheet offers **Turn On Grok Build's Status**. It shows the file and the exact lines, `program_status = "on"` under `[ui.notifications]` in `$GROK_HOME/config.toml` or `~/.grok/config.toml`, and writes nothing until you tap **Apply This Change**. Start Grok Build again to see its status. A managed configuration or a `GROK_CONFIG` overlay can still override this file.

If the file changed after Heeler read it, Heeler writes nothing and says so. If Heeler cannot read the Agent's environment, it cannot tell which file that Agent uses, so it writes nothing and says so. If Heeler cannot be sure how to change a file, it writes nothing and tells you what to add by hand.

**Undo** in the same sheet, or under **Harness Edits** in the Host's detail, puts the file back exactly as it was. It writes nothing if the file has changed since the edit. In that case undo the edit by hand, and **Stop Listing** drops it from the list. Each sheet speaks for the file its Agent reads, so Agents with different `GROK_HOME` values each get their own change and **Undo**, and each row under **Harness Edits** undoes the file it shows. The list belongs to the device that made the edit. Heeler never edits Claude Code's settings, Codex's hooks or trusted hashes, or Grok Build's global hooks.

A row opens the Agent's detail. Its menu has Open in New Window where the device has windows, and Close.

**Agent List Fields** in Settings sets a core Host's rows, starting from Heeler's own fields. It offers the labels of the Host's Terminals, and no Sync from plugin, since no plugin runs there. Each row has a right side for the status badge and Changes totals, and **Apply to All Hosts** copies a Host's fields to your other Hosts.

**Pins** are per Host and survive a core restart. A Pin goes when you close the Agent from its row, or close the Tab it is in, and when its Terminal is removed. All of a Host's Pins go when its core was wiped and started new.

## Terminal

Every terminal is a channel on the Host's one connection, so opening more costs no new SSH session. It is one of any number of viewers: the desktop app can stay attached, typing takes the size, and no Take Over appears. Scrollback comes with it. Up to five terminals stay ready for five minutes after you leave them, and come back at once.

Every key reaches the program, Ctrl+\ included. Heeler reserves no detach key.

In an Agent detail, Direct Input types into the terminal, and Changes and Skills work as on any other Host.

## Send

On a macOS or Linux Host, the Composer's Send writes into the terminal you are viewing, in two steps. It pastes the draft, checks that the same Agent still holds the terminal, then presses Enter, or the submit key of the Template the Terminal came from. That takes a little over half a second, and if the terminal is not connected yet, Send opens it first.

The submit goes out within two seconds of the paste or not at all, so a slow link or an Agent that quit never turns your message into a shell command. When it does not go out, the draft stays in the Composer and a notice says what happened:

| Notice | What it means | What to do |
| --- | --- | --- |
| **stayed in the Agent's input unsubmitted** | The Agent still holds the terminal, and the check took longer than two seconds | Finish it in the terminal, or clear it there before you send again |
| **no longer in the terminal** | The Agent left and a shell took over. Send pressed Ctrl+C once, which made the shell drop the text unrun | Send again once the Agent is back |
| **may still be in the terminal** | The Agent left and something else holds the terminal. Under a shell Send pressed Ctrl+C once, and what zsh does with that is not confirmed yet | Check the terminal before you press anything there |
| **not accepting a paste** | The program has bracketed paste off, so nothing was written | Send again when it is back at its input |

While the Agent is **Blocked**, Send only pastes. Use the tools keyboard to submit or cancel.

If the Host does not answer a step, Send cannot tell what reached the program. The Composer says so, offers **Edit Draft** instead of Retry, and never sends the message again, because a paste or an Enter the core was holding can still arrive. Look at the terminal first. The next Send pastes nothing until the Host answers, then says the last message **may still be in the Agent's input**. Check the terminal and send again.

Send appears once the connection has told Heeler the Host's platform, a moment after the detail opens.

## Images and files

On a macOS or Linux Host, **Add** in the Composer, or **Add Image** and **Add File** under More in Direct Input, stages an image or file as on any other Host. Heeler uploads it over SFTP, puts its path on the Host in your draft, and copies the path. Nothing reaches the Agent until you send: the draft waits, and [Send](#send) delivers it with the path in it.

Add appears once the connection has told Heeler the Host's platform, a moment after the detail opens.

## Stop

While an Agent is **Working** and the draft is empty, **Stop** takes Send's place. Heeler asks the core to press the Terminal's own stop key: the stop key of the Template the Terminal came from, else Esc. It then reads whether the program still runs, so an Agent that exits at the key leaves the list without waiting for the next update. Each tap presses once, and Heeler never presses again by itself.

Stop shows only while the Agent holds the terminal, never for the shell it left behind. A program that has not reported a status reads **Unknown** and has no Stop. Use the tools keyboard or Direct Input there.

A Grok Build Agent's Composer keeps **Send** while it works, as on any other Host, because Esc does not stop its turns. Use the tools keyboard or Direct Input to press Ctrl+C.

| Notice | What it means | What to do |
| --- | --- | --- |
| **still shows Working** | The key went and the Agent is still Working a few seconds later. A background task can do that | Tap **Stop** again if you still want it to stop |
| **may or may not have reached the Agent** | The connection dropped or went silent during Stop, so Heeler cannot tell, and it does not send it again | Look at the terminal first |
| **did not say whether the Agent still runs** | The Host answered that it pressed the key, and the check after it got no answer | Look at the terminal |
| **wasn't sent** | The connection was down, or too busy to take Stop within a few seconds. No key was pressed | Tap **Stop** again |

## Restarts and ended Terminals

| What happened | Heeler shows |
| --- | --- |
| A kept Terminal lost its program, for example to a crash or a signal | **Restarting…** The core brings the Terminal back as a new shell at the same address, and an open terminal reattaches by itself, with no error and nothing to tap. An Agent detail stays open over the new shell |
| A program exited, including your own `exit` | **Agent Ended** in an Agent detail, with its exit code when the core reports one, or **Terminal Closed** on a Terminal's own screen. The Terminal has ended for good, so nothing reattaches |

The new shell is no Agent until you start one in it.

A dropped connection is not an end. An open Agent detail keeps its screen and draft with **Reconnecting…** in its title, and takes no input until the Host answers again. Once the core answers, its list decides whether the Agent is still there.

Another core at the same socket, such as one started under another state directory, has its own Terminals, even at the same address. A terminal you had open shows as ended, and says it belongs to a core that is gone. A Chat you had open gives way to that terminal. Anything you tap waits for the new core's list, and after that the screen you had open sends nothing: Close, Send, Stop and answers to the Agent all say the Terminal belongs to a core that is gone. This holds even if the screen was rebuilt while the Host was reconnecting. Open the Terminal again from that list, and what you open there, like the list's own rows, acts on the new core. On iPad the row is no longer marked as selected, and tapping it opens the new core's Terminal.

## Close

Closing a Tab on a core Host ends its Terminals for good, and closing a Pane ends that one Terminal. A kept Terminal does not come back as a shell, and it leaves the Console once the core reports it ended. Close works the same from an Agent's or a Terminal's row, Agent detail and a Shell Terminal.

The Host keeps the ended Terminal's record, and Heeler does not show it.

If the Host does not confirm a close, Heeler says so and does not send it again, since the Terminal may already have ended. Check it before trying again.

## Core Environment

A core started from inside another program can inherit variables that change how its programs behave. Host detail then shows **Core Environment**, naming each variable and what it breaks, never its value. Restarting the core from your own terminal fixes it. Heeler does not restart it.

## New Agent and New Terminal

**New Agent** lists the agents your own shell can run, and starts the one you pick through that shell, so it has the `PATH` and variables your startup files set. An alias or a shell function does not count, since a start runs a program on that `PATH`. That shell is your login shell on the Host, bash, zsh and fish alike. Arguments you type stay whole, however many spaces, quotes or `$` they hold.

If the program has already ended when the Host answers the start, the form stays open and says so, with its exit code. Exit code 127 means your shell could not find the command. Otherwise New Agent closes and opens the Agent, and a program that ends then reads **Agent Ended** with its exit code.

Pick where it starts, for an Agent and for **New Terminal** alike:

| You pick | It starts | It shows |
| --- | --- | --- |
| A desktop space | In the directory of the Agent you started from, else the space's folder | In a new tab of that space, here and in the desktop app |
| A directory's Workspace | In that Workspace's directory, even after a Terminal in it moved elsewhere | In that Workspace, and not in the desktop app's layout until you adopt it there |
| **New Workspace** or **Browse Directory…** | In the directory you chose | In a new Workspace of its own, even when another already uses that directory. A running desktop app shows it as a new space. Until the desktop app names it, it is named for its first Terminal's checkout folder |

Heeler asks for no tab or Workspace name on this kind of Host.

Heeler gives an Agent a session of its own from the start where the program takes one, unless your arguments already pick a session, as `--resume` does. Codex runs with `--no-daemon`. OpenCode gets its session only from version 2.1.

If the Host does not confirm a start, Heeler says so and does not try again, since the Agent may already be running. Check the Host before starting another.

### Templates

**New Agent** also lists the Host's Templates, the roles saved under `~/.config/herdr-core/templates` (or `$XDG_CONFIG_HOME/herdr-core/templates`), under the agents your shell can run. A file the core cannot use is not listed. A Template removed after you opened the form is no longer started: **Detect Again** refreshes the list. If it goes in the moment before the start, the core runs a program of that name instead, and Heeler says so and where.

Pick one and tap **Start**. It lands where any other Agent would, by the table above, and an empty name field names the Agent after the Template, or `reviewer-2` while another live Terminal is named `reviewer`. The core runs the Template's own command, so your shell, your startup files and the session flags above play no part, and the form asks for no arguments. A command that needs a variable from your startup files should set it itself.

A Template that has a first message answers only once its program first reports, which can take up to 35 seconds. New Agent shows it starting for that long. A program that has not reported after 30 seconds still starts, but the core does not type the first message and Heeler does not say so, so check its screen. If the Host does not answer at all, Heeler says it did not confirm the start and does not try again.

A program Heeler does not know joins the Agents once it reports a status. Until then it stays in the Terminals tab, and New Agent closes without opening it.

If the program ends during the few seconds New Agent watches it, the form stays open and says so, with its exit code. Exit code 127 means the core could not find the command, so give it a full path or set `PATH` in the command. A program that ends after the form has closed leaves the Terminals tab like any other that ended.

**Known limit:** with zsh as your login shell and no startup files, such as no `~/.zshrc`, zsh opens its new-user wizard and the Agent waits behind it. Open the Terminal and answer the wizard once, or create an empty `~/.zshrc` on the Host first.

## Worktrees

On macOS and Linux, **New Agent** can start an agent or a Template in a new Worktree of the Workspace you pick. Turn on **Start in a new worktree** and type a branch. A branch that exists is checked out, and a new one starts from the Workspace's current commit.

The checkout goes to `~/.herdr/worktrees/<repository>/<branch>`, where the desktop app puts its own. `<repository>` is the main checkout's folder name, and in the branch's folder name anything other than letters, digits, `.`, `_` and `-` reads `-`. It opens as a new Workspace, which a running desktop app shows as a new space.

To remove one, open an Agent in it, then **Worktree Details** in the More menu. Heeler first ends every Terminal of that Workspace, as Close does, then removes the checkout. **Remove Worktree** becomes available once Heeler has checked the checkout, and the confirmation warns when uncommitted changes or submodules would go with it. The branch stays.

If a Terminal cannot be confirmed ended, Heeler says so and leaves the checkout in place. Check the Host before trying again. The same goes if the checkout changed while its Terminals were ending: they have ended, the checkout stays, and the next confirmation warns about what it holds now. Removing ends only that Workspace. Another Workspace on the same checkout keeps running in the deleted folder, whether it started there or a Terminal moved in, so the confirmation names any it can tell. Close those first.

If the connection drops with **Worktree Details** open, the sheet goes with the Agent's screen. Whatever stopped the removal, or the Host not confirming it, then shows as an alert over the Console, and so does a Close that ends the same way from an Agent's screen. Check the Host before trying again.

## Chat

Chat opens for a Claude Code Agent on a Linux core Host, where you can read its conversation, send to it, stop it and answer its questions. Chat for Codex, Grok Build and OpenCode 2.x on Linux is built and turned on one program at a time, each once it has passed a check with a signed-in account. Until then, those Agents offer the terminal alone. The rows below say what to expect from each.

- **Send** checks the Agent's input box and which conversation it shows, pastes the message, and submits it only if the same Agent still holds the terminal within two seconds. Otherwise nothing is submitted, the draft stays in the Composer, and a notice says whether the text may still be in the terminal. A Send the Host did not answer is never sent again, so check the terminal before sending it yourself. Its message says it **may or may not have reached the Agent**, until the conversation shows it arrived. The next Send pastes nothing until the Host answers, then says the last message **may still be in the Agent's input**.
- **Stop** presses Esc, or on a Template's Terminal the Template's stop key.
- A **Blocked card** answers only while the same dialog is on screen and the Agent still holds the terminal. If either changed, it sends nothing and says so.

Typing from Chat does not change the terminal's size for anyone viewing it.

Heeler finds the conversation from the Agent's own process on the Host, with nothing to install, and never guesses from a directory or the newest file. It follows Claude Code's `/clear` and `/resume`, and reads from the `CLAUDE_CONFIG_DIR`, `CODEX_HOME` or `GROK_HOME` the Agent itself runs with. It checks when you open or return to Chat, before each Send, when you retry, when a reconnect or the Agent's return brings its Terminal back, and when the Agent's status, turn, foreground program or session label changes. No timer checks in between.

When Chat says **Can't Tell the Conversation**, the fix it names is still the better one. If you want Chat now, tap **Choose a Conversation**. It lists the conversations the Agent's process holds open, the ones its status names, and the newest ones in its directory. Open one to read it, then tap **Use This Conversation**. Chat binds only then, and any device that opens this Agent's Chat follows the same choice. If Heeler sent your choice and got no answer, it says so and does not send it again. Chat shows the conversation if the choice landed.

Your choice is dropped, and Chat goes back to **Can't Tell the Conversation**, when:

- another process takes over the terminal, such as the program restarting
- the program names a session for itself, or Chat finds exact evidence
- a message you sent from Chat is missing from the conversation once the Agent's next turn ends

Codex on its shared background server offers no list, only `codex resume --no-daemon`. Herdr TUI Hosts name the conversation themselves and offer no list.

| Chat says | What it means |
| --- | --- |
| **Can't Tell the Conversation** | Claude Code names its conversation only once it reaches its prompt. Finish signing in or answer its question in the terminal, and Chat follows on the next status change. **Retry** checks at once |
| **Can't Tell the Conversation**, on Codex | Codex shows its conversation with the first message, so send one in the terminal. Once a message follows `/new`, nothing says which conversation is on screen: exit Codex, run `codex resume --no-daemon` and pick the conversation |
| **Can't Tell the Conversation**, on Grok Build | Grok Build lists its conversation while it runs. After `/new` it lists both, and Chat can't tell until you start Grok Build again |
| **Can't Tell the Conversation**, on OpenCode | Heeler can name OpenCode's conversation only when it starts OpenCode 2.1 or later itself, from New Agent. A hand-started or older OpenCode, or a Template's, stays this way |
| **Codex Started Without `--no-daemon`** | Codex runs on its shared background server, where one terminal's conversation looks like another's. Exit Codex, run `codex resume --no-daemon` and pick the conversation in Codex's list. New Agent starts Codex this way itself, so this comes from a Codex you started by hand or a Template |
| **Transcript Saving Is Off** | The Agent runs with the variable Chat names, `CLAUDE_CODE_CHILD_SESSION` or `CLAUDE_CODE_SKIP_PROMPT_HISTORY`, so it keeps no conversation to read. Start it again without the variable. If the core itself carries it, the Host's **Core Environment** says how to fix that |
| **Restarting…**, **The Agent ended** or **The Agent is gone** | The program in the Agent's Terminal was lost, exited, or gave way to a shell. Chat stays on the conversation and sends nothing, and follows the next Claude Code started at that address |

### Pi and Oh My Pi

Chat for Pi and Oh My Pi stays off until each program passes a check with a signed-in account, so for now both offer the terminal alone. Once a program's Chat is on, it works like this:

- **With the [Host Helper](#host-helper)**, Heeler's extension names the conversation, however the Agent started: New Agent, a Template, `hc run` or a shell. Chat follows `/new` at its next check. An Agent already running when you install the Helper needs starting again.
- **Pi without the Helper** opens only if Heeler started it, from the session id Heeler gave it. Chat waits for the first message, and keeps showing that conversation after a `/new`, which it cannot notice. Sending still reaches the session the program shows.
- **Oh My Pi without the Helper** opens once the first message makes the process hold its session file, and follows `/new` the same way. Until then its conversation has no proof yet, so Chat says it can't tell.

Anything else reads **Can't Tell the Conversation**, and the message points you to installing the Helper from the Host's details. Heeler never picks the newest file or goes by the directory.

Heeler looks for the sessions where the Agent's own environment says: `PI_CODING_AGENT_DIR` and `PI_CODING_AGENT_SESSION_DIR` for Pi, `PI_CONFIG_DIR`, `OMP_PROFILE`, `PI_PROFILE` and `PI_CODING_AGENT_DIR` for Oh My Pi. It cannot see a folder set any other way, such as Pi's `--session-dir` or `sessionDir` setting, Oh My Pi's `--profile` flag or `.env` file, or its files after `omp config init-xdg`. With the Helper, the extension names the file itself and Chat reads it. Without it, Chat stays on **Can't Tell the Conversation**, or for a Pi Heeler started, keeps waiting for a first message it cannot find.

## Known limits

- Heeler has no Rename on a core Host yet. Use the Host or the Herdr desktop app.
- Chat opens for Claude Code on Linux, and for Codex, Grok Build, OpenCode 2.x, [Pi and Oh My Pi](#pi-and-oh-my-pi) once each has passed its check. Until then those Agents, and every Agent on a macOS or native Windows core Host, offer the terminal alone.
- After you choose a conversation for a Pi without the [Host Helper](#host-helper) or an OpenCode without its plugin, an in-process `/new` changes nothing Heeler can see. Chat keeps showing the old conversation until a message you send from Chat fails to appear in it, and only then drops your choice. A program that reports no status never ends a turn, so that check waits until it does.
- Right after `/new` in Codex, before any message there, nothing on the Host has changed. Chat keeps showing the old conversation, and a Send goes to the new one. After `/new`, keep to the terminal until you have exited Codex and run `codex resume --no-daemon`.
- After `/new` or a pick in OpenCode's list, Chat keeps showing the conversation OpenCode started with until you start OpenCode again. Its terminal title is what says the screen moved, so a Send sends nothing and says why. With OpenCode's `terminal.title` setting off, or while Chat's conversation has no title of its own, the title can't tell, and a Send goes to whatever conversation is on screen. Only OpenCode's home screen still holds it.
- Terminals federated from another machine are omitted. Add that machine as a Host of its own, so its file operations reach the right computer.
- If the connection drops while an Agent detail is open on a Terminal that lost its program or ended, the detail reads **Agent Gone** after the reconnect. A restored Terminal has its row in the Terminals tab.
- If Heeler cannot read its saved herdr-core Hosts, the Hosts tab says so. Herdr TUI Hosts keep working and the saved data stays as it was, but no herdr-core Host can be added until it reads again.

## Host Helper

The Host Helper is Heeler's own background service on a herdr-core Host. It stands in for the Heeler plugin, which core cannot run, and it runs on the Host's Node.js. It follows the core, sends Agent Notifications and Live Activity updates, and answers Usage.

The Helper never starts a core. It connects to the core's socket directly, and while no core runs it waits and tries again, so a core you stopped stays stopped until you start it. When you do, the Helper connects on its own, without a restart.

**Install.** Open the Host's detail and tap **Host Helper**. The sheet lists every file the install writes, including its systemd user unit on Linux or its LaunchAgent property list on macOS. Tap **Install**. If the sheet could not read the list, the first tap only reads it again and writes nothing. The files go in `~/.local/share/heeler/host-helper` (or under `XDG_DATA_HOME`) on Linux and in `~/Library/Application Support/heeler/host-helper` on macOS, and are private to your account. Heeler replaces a Helper only with a newer version, or when it is missing or damaged, and never one that a newer version of the app installed.

The install also places Heeler's extension for Pi in `~/.pi/agent/extensions` and for Oh My Pi in each profile's `agent/extensions` folder, also listed in the sheet. Those programs load it on their own, so no configuration file changes. It does nothing outside a herdr-core Terminal. Inside one it tells the Terminal which session the program is on, for Chat, and Pi releases before 1.1.0 also report their status through it. An Oh My Pi profile you add later gets its extension from **Repair** in the sheet.

On Linux, without systemd linger, the Helper stops about ten seconds after your last login to the Host ends. The sheet checks it and offers **Turn On Linger**. Some Hosts ask for an administrator instead: the sheet shows the Host's reason, and an administrator can run `loginctl enable-linger <your-user>` there.

On macOS there is no linger to turn on: the Helper keeps running after your SSH session and a desktop logout. It writes its log to `helper.log` in its directory. macOS may notify you that `node` can run in the background and list it under Login Items, because that is the program the Helper runs on.

After a restart of the Mac the Helper may not be running until Heeler next reaches the Host, when it starts it again without asking. No notification goes out in between.

**Check.** The Host Helper row shows the Host's state each time you check the Host. On macOS the row takes about eleven seconds, because one look cannot tell a Helper that runs from one that keeps dying:

| Row reads | What it means |
| --- | --- |
| **Not Installed** | No Helper on this Host |
| A version | Installed and running. The sheet says when this app carries a newer one |
| A newer version | A newer version of Heeler installed it, and it runs. Update the app to change it |
| **Damaged** | Files are missing or changed. **Repair** puts them back |
| **Node.js Missing** | The Host has no Node.js, or one too old to run the Helper |
| **Linger Off** | Runs only while you are logged in |
| **Service Failed** | The service stopped and will not start again by itself, or on macOS keeps failing, for example after Node.js moved. **Repair** sets it up with the Node.js the Host has now. A Helper a newer version of Heeler installed reads this too, and updating the app is what changes it |
| **Not Available** | This platform has no Helper |

Native Windows Hosts read **Not Available**, so Agent Notifications (in-app banners included), Live Activity and Usage are not available there yet.

**Remove.** In the sheet, tap **Remove**. Heeler stops the service, deletes the files the install recorded, the Pi and Oh My Pi extensions among them, then the folders it created that are now empty, and finally the Helper's directory with its notification registrations and seen marks. The Host's banners and Live Activity stop with it. Removal leaves systemd linger and the Grok Build edit (`program_status` in its configuration) as they are: change those yourself if you no longer want them.

## Agent Notifications

With the Host Helper running, a herdr-core Host notifies you as any other Host does, with Heeler killed too. Turn notifications on for the Host in **Settings > Notifications**. Heeler writes this device's entry for the Host's session into the Helper's directory, never into a plugin's file, and each device's notifications are encrypted with its own key.

- **Blocked** and **Error** come under the Blocked switch. Error reads as Error, since nothing is waiting for your answer.
- **Done** has its own switch, and is per device. A device gets no Done for a turn it has seen: it had the Agent open as the turn ended, or opened the Agent before the notification was due. To know that, Heeler writes a small file for this device in the Helper's directory, holding only Terminal addresses and turn counts, whenever you open an Agent or a turn ends while it is open. Your other devices still get theirs.
- A Terminal that has no Agent, or whose Agent has given way to a shell, sends nothing. A status that lasts under about five seconds sends nothing either.
- What a core had already reported when the Helper first saw it is not announced.
- If the Helper cannot reach the Push Relay, it tries again by itself for about twelve minutes, for the devices that missed it and only while what it says still holds. After that, the Terminal's next change tries again.

Turning notifications off, or removing the Host while Heeler can reach it, with its core stopped too, removes this device's entry and its file from the Host. If you remove a Host Heeler cannot reach, the entry stays and Heeler says so: reconnect first to stop them.

The switches need the Helper, so **Settings > Notifications** says what the Host's Helper needs, such as **Not Installed**, **Service Failed** or **Node.js Missing**. Fix that from the Host's page in **Hosts**. A device already registered keeps its switches there, so it can still leave. With **Linger Off**, the switches work and a note says the Helper stops about ten seconds after your last login ends, so notifications stop too.

### Banners and Live Activity

Once this device is registered with a Host's Helper, that Host's Agents join the in-app banners and the Live Activity alongside your other Hosts. A Host without the Helper, or without this device's registration, gets neither.

- **Banners** come while Heeler is open, under the same switches: Blocked and Error under the Blocked switch, Error reading as Error, and Done under its own switch. Done is this device's, so an Agent you have open makes no Done banner.
- **Live Activity** has its own switch for the Host. Heeler starts the activity and writes its push token into the Helper's directory. After Heeler suspends, the Helper updates and ends it through the Push Relay. Done counts for this device only, and an Error Agent counts under Blocked, as the Live Activity has no count of its own for it.

While Heeler is suspended the activity names each Agent's workspace by its folder, not a desktop app's space name, and a row field for the Tab or Pane stays empty. Opening Heeler brings those back.

## Usage

With the Helper installed, a core Host's Usage works as on any other Host, in the Usage tab, the Host's detail and the widgets: Token Usage for Claude Code and Codex, and Claude Code's Usage Limits when you turn them on for that Host. Turning **Usage** off in **Settings** covers core Hosts too: Heeler stops asking their Helpers, and the Helpers themselves stay installed.

The **Default Account** follows the core, not your SSH login. A core usually starts from the desktop app or a login shell, with an environment SSH never sees, so the Helper reads the variables that locate Accounts, such as `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, from the core process. It reads those by name and nothing else, keeps them in a file only your account can read, and reads them again whenever the core restarts. Change `CLAUDE_CONFIG_DIR` and restart the core to move the Default Account.

To count more Claude Code sign-ins, open **Claude Code Accounts**. Heeler suggests the directories of the Claude Code Agents running in the core and those it finds in your home folder. Your choices stay in the Helper's directory, so **Remove** deletes them with it.

| Usage reads | What to do |
| --- | --- |
| **Usage needs the Host Helper** | See the Host Helper row on the Host's detail, which says whether this Host can take one |
| **Usage needs a newer Host Helper** | Update it from the Host's detail |
| **The Host Helper has not reached this session's core yet** | Start the core if it is not running. Heeler keeps checking, and the Helper never starts one |
| **Usage comes with the Host Helper, which is not available on native Windows yet** | Nothing for now |

On macOS, Claude Code keeps its sign-in in the login keychain, which neither the Helper nor SSH can reach, so its Usage Limits read **need your own login on this Mac**. Token Usage still counts.

Usage reaches the Helper over its own SSH connection when the Host's session has none, so these read the same whether the core is running or not. **Not connected** in the Usage tab and the widgets means SSH itself could not reach the Host.

The Usage widgets say the same in a shorter form, such as **Needs the Host Helper**. With a widget installed, Heeler checks each core Host when you open the app, so you do not have to open Usage for the widget to catch up.
