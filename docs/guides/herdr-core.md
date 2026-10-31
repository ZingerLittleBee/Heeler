# Connect herdr-core

Agents started by the desktop herdr-app belong to herdr-core, a server of their own. They do not appear in the Herdr TUI server, even when both run under the same SSH account, so each one is a Host of its own in Heeler. Heeler reads herdr-core 0.1.13. The app and the core have separate version numbers.

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

Heeler never starts a core by connecting or checking, so a mistyped session name reads **herdr-core is not running** rather than an empty, new core. While the core is not running, the checks try again by themselves.

| Host reads | What to do |
| --- | --- |
| **herdr-core is not installed** | Install it on the SSH PATH or at `~/.local/bin/herdr-core`, then check again |
| **herdr-core is not running**, nothing listening at a socket path | Start the core. Check the session name if you expected it running |
| **herdr-core is not running**, a socket file left behind | Start the core, or allow stream-local forwarding in the Host's SSH server. Heeler cannot tell these two apart from here |
| **The SSH server refuses socket forwarding** | Allow stream-local forwarding in the Host's SSH server |
| **herdr-core needs an update** | Run the update command it shows, then check again |
| **The herdr-core socket path is too long** | Use a shorter session name, or set a shorter socket in the core's config |

**Start herdr-core** appears under the checks on a Linux Host whose core is not running. It asks first, naming the session, the interactive login shell it starts through, and systemd linger, which it tries to turn on when it is off. The core then has the environment your own terminal has. If a core was already running by then, Heeler says so and that Start changed nothing. On macOS and Windows, Heeler says how to start the core yourself.

## Console

A core Host's Terminals follow the Herdr desktop's organization when the core has one. Heeler reads it and never changes it.

- Each desktop space is a card under its own name, in the desktop's order. A row reads **Tab “name”**, or **Tab N** for a tab with no name.
- A space that only a Terminal's label names follows the desktop's spaces, named for the folder of its git checkout, or for its directory outside one.
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

Done is per device. An Agent shows Done when it finished a turn this device was not showing and still reports idle or done. Opening the Agent clears it here, and so does having it open when the turn ends; your other devices keep showing it until you open it there. It leaves on its own when the Agent starts working again. A turn finishes when a program goes from Working to Done. A program not known to report done also finishes one by going from Working to Idle, while Claude Code, Codex, Pi and Oh My Pi do not, so a Codex release too old to report done never shows Done. Removing the Host, or the Host getting a different core, starts over.

Tap **Unknown** on an Agent's status line to see why it reads that way. Each program reports its status from a release on: Claude Code 2.1.295, Codex 0.163, OpenCode 2.1, Pi 1.1.0 (earlier releases report through the [Host Helper](#host-helper)) and Oh My Pi 18.8.7, so an older one stays Unknown. No such release is known for Grok Build or for a program Heeler does not recognize. A Terminal that has reported but holds no state reads as not having reported a state yet. Heeler never works out a status from the screen.

**Grok Build's status.** Grok Build's automatic check leaves its status off where its query cannot run, such as under a core started with `TMUX` set. On a Grok Build Agent with no status, that same sheet offers **Turn On Grok Build's Status**. It shows the file and the exact lines, `program_status = "on"` under `[ui.notifications]` in `$GROK_HOME/config.toml` or `~/.grok/config.toml`, and writes nothing until you tap **Apply This Change**. Start Grok Build again to see its status. A managed configuration or a `GROK_CONFIG` overlay can still override this file.

If the file changed after Heeler read it, Heeler writes nothing and says so. If Heeler cannot read the Agent's environment, it cannot tell which file that Agent uses, so it writes nothing and says so. If Heeler cannot be sure how to change a file, it writes nothing and tells you what to add by hand. A native Windows Host takes this change by hand too.

**Undo** in the same sheet, or under **Harness Edits** in the Host's detail, puts the file back exactly as it was. It writes nothing if the file has changed since the edit. In that case undo the edit by hand, and **Stop Listing** drops it from the list. Each sheet speaks for the file its Agent reads, so Agents with different `GROK_HOME` values each get their own change and **Undo**, and each row under **Harness Edits** undoes the file it shows. The list belongs to the device that made the edit. Heeler never edits Claude Code's settings, Codex's hooks or trusted hashes, or Grok Build's global hooks.

A row opens the Agent's detail. Its menu has Open in New Window where the device has windows, and Close.

**Agent List Fields** in Settings sets a core Host's rows, starting from Heeler's own fields. It offers the labels of the Host's Terminals, and no Sync from plugin, since no plugin runs there.

**Pins** are per Host and survive a core restart. A Pin goes when you close the Agent from its row, or close the Tab it is in, and when its Terminal is removed. All of a Host's Pins go when its core was wiped and started new.

## Terminal

Every terminal is a channel on the Host's one connection, so opening more costs no new SSH session. It is one of any number of viewers: the desktop can stay attached, typing takes the size, and no Take Over appears. Scrollback comes with it. Up to five terminals stay ready for five minutes after you leave them, and come back at once.

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

If the Host does not answer a step, Send cannot tell what reached the program. The Composer says so, offers **Edit Draft** instead of Retry, and never sends the message again, because a paste or an Enter the core was holding can still arrive. Look at the terminal first.

Send appears once the connection has told Heeler the Host's platform, a moment after the detail opens. Native Windows core Hosts do not offer it yet.

## Images and files

On a macOS or Linux Host, **Add** in the Composer, or **Add Image** and **Add File** under More in Direct Input, stages an image or file as on any other Host. Heeler uploads it over SFTP, puts its path on the Host in your draft, and copies the path. Nothing reaches the Agent yet: the draft waits, and since a core Host has no Send yet, paste the path into the terminal to use it.

Add appears once the connection has told Heeler the Host's platform, a moment after the detail opens. Native Windows core Hosts do not offer it yet.

## Stop

While an Agent is **Working** and the draft is empty, **Stop** takes Send's place. Heeler asks the core to press the Terminal's own stop key: the stop key of the Template the Terminal came from, else Esc. It then reads whether the program still runs, so an Agent that exits at the key leaves the list without waiting for the next update. Each tap presses once, and Heeler never presses again by itself.

Stop shows only while the Agent holds the terminal, never for the shell it left behind. A program that has not reported a status reads **Unknown** and has no Stop. Use the tools keyboard or Direct Input there.

A Grok Build Agent's Composer keeps **Send** while it works, as on any other Host, because Esc does not stop its turns. Use the tools keyboard or Direct Input to press Ctrl+C.

On a native Windows Host, Stop is not available yet.

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
| A program exited, including your own `exit` | **Agent Ended** in an Agent detail, or **Terminal Closed** on a Terminal's own screen. The Terminal has ended for good, so nothing reattaches |

The new shell is no Agent until you start one in it.

## Close

Closing a Tab on a core Host ends its Terminals for good, and closing a Pane ends that one Terminal. A kept Terminal does not come back as a shell, and it leaves the Console once the core reports it ended. Close works the same from an Agent's or a Terminal's row, Agent detail and a Shell Terminal.

The Host keeps the ended Terminal's record, and Heeler does not show it.

If the Host does not confirm a close, Heeler says so and does not send it again, since the Terminal may already have ended. Check it before trying again.

## Core Environment

A core started from inside another program can inherit variables that change how its programs behave. Host detail then shows **Core Environment**, naming each variable and what it breaks, never its value. Restarting the core from your own terminal fixes it. Heeler does not restart it.

## New Agent and New Terminal

**New Agent** lists the agents your own shell can run, and starts the one you pick through that shell, so it has the `PATH` and variables your startup files set. That shell is your login shell on the Host, bash, zsh and fish alike. Arguments you type stay whole, however many spaces, quotes or `$` they hold.

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

**New Agent** also lists the Host's Templates, the roles saved under `~/.config/herdr-core/templates` (or `$XDG_CONFIG_HOME/herdr-core/templates`), under the agents your shell can run. A file the core cannot use is not listed.

Pick one and tap **Start**. It lands where any other Agent would, by the table above, and an empty name field names the Agent after the Template, or `reviewer-2` while another live Terminal is named `reviewer`. The core runs the Template's own command, so your shell, your startup files and the session flags above play no part, and the form asks for no arguments. A command that needs a variable from your startup files should set it itself.

A Template that has a first message answers only once its program first reports, which can take up to 35 seconds. New Agent shows it starting for that long. A program that has not reported after 30 seconds still starts, but the core does not type the first message and Heeler does not say so, so check its screen. If the Host does not answer at all, Heeler says it did not confirm the start and does not try again.

A program Heeler does not know joins the Agents once it reports a status. Until then it stays in the Terminals tab, and New Agent closes without opening it.

If the program ends during the few seconds New Agent watches it, the form stays open and says so, with its exit code. Exit code 127 means the core could not find the command, so give it a full path or set `PATH` in the command. A program that ends after the form has closed leaves the Terminals tab like any other that ended.

**Known limit:** with zsh as your login shell and no startup files, such as no `~/.zshrc`, zsh opens its new-user wizard and the Agent waits behind it. Open the Terminal and answer the wizard once, or create an empty `~/.zshrc` on the Host first.

## Worktrees

On macOS and Linux, **New Agent** can start an agent or a Template in a new Worktree of the Workspace you pick. Turn on **Start in a new worktree** and type a branch. A branch that exists is checked out, and a new one starts from the Workspace's current commit.

The checkout goes to `~/.herdr/worktrees/<repository>/<branch>`, where the desktop app puts its own. `<repository>` is the main checkout's folder name, and in the branch's folder name anything other than letters, digits, `.`, `_` and `-` reads `-`. It opens as a new Workspace, which a running desktop app shows as a new space.

To remove one, open an Agent in it, then **Worktree Details** in the More menu. Heeler first ends every Terminal of that Workspace, as Close does, then removes the checkout. **Remove Worktree** becomes available once Heeler has checked the checkout, and the confirmation warns when uncommitted changes or submodules would go with it. The branch stays.

If a Terminal cannot be confirmed ended, Heeler says so and leaves the checkout in place. Check the Host before trying again. A Terminal in another Workspace that has moved into the checkout is not ended, so close it first.

Native Windows core Hosts do not offer Worktrees yet.

## Chat

Chat opens for a Claude Code Agent on a Linux core Host, where you can read its conversation, send to it, stop it and answer its questions.

- **Send** checks the Agent's input box and which conversation it shows, pastes the message, and submits it only if the same Agent still holds the terminal within two seconds. Otherwise nothing is submitted, the draft stays in the Composer, and a notice says whether the text may still be in the terminal. A Send the Host did not answer is never sent again, so check the terminal before sending it yourself.
- **Stop** presses Esc, or on a Template's Terminal the Template's stop key.
- A **Blocked card** answers only while the same dialog is on screen and the Agent still holds the terminal. If either changed, it sends nothing and says so.

Typing from Chat does not change the terminal's size for anyone viewing it.

Heeler finds the conversation from the Agent's own process on the Host, with nothing to install, and never guesses from a directory or the newest file. It follows `/clear` and `/resume`, and reads from the `CLAUDE_CONFIG_DIR` the Agent itself runs with. It checks when you open Chat and when the Agent's status or foreground program changes, and at no other time.

| Chat says | What it means |
| --- | --- |
| **Can't Tell the Conversation** | Claude Code names its conversation only once it reaches its prompt. Finish signing in or answer its question in the terminal, and Chat follows on the next status change. **Retry** checks at once |
| **Transcript Saving Is Off** | The Agent runs with the variable Chat names, `CLAUDE_CODE_CHILD_SESSION` or `CLAUDE_CODE_SKIP_PROMPT_HISTORY`, so it keeps no conversation to read. Start it again without the variable. If the core itself carries it, the Host's **Core Environment** says how to fix that |

## Known limits

- Heeler has no Rename on a core Host yet. Use the Host or the desktop.
- Chat opens only for Claude Code on Linux. Other programs, macOS and native Windows core Hosts offer the terminal alone.
- Native Windows core Hosts offer no Send or Stop yet. To stop an Agent or type on Windows, use the tools keyboard or Direct Input.
- Terminals federated from another machine are omitted. Add that machine as a Host of its own, so its file operations reach the right computer.
- If the connection drops while an Agent detail is open on a Terminal that lost its program or ended, the detail reads **Agent Gone** after the reconnect. A restored Terminal has its row in the Terminals tab.

## Host Helper

The Host Helper is Heeler's own background service on a herdr-core Host. It stands in for the Heeler plugin, which core cannot run, and it runs on the Host's Node.js. It follows the core, sends Agent Notifications and Live Activity updates, and answers Usage.

The Helper never starts a core. It connects to the core's socket directly, and while no core runs it waits and tries again, so a core you stopped stays stopped until you start it. When you do, the Helper connects on its own, without a restart.

**Install on Linux.** Open the Host's detail and tap **Host Helper**. The sheet lists every file the install writes, including its systemd user unit. Tap **Install**. The files go in `~/.local/share/heeler/host-helper` (or under `XDG_DATA_HOME`) and are private to your account. Heeler replaces a Helper only with a newer version, or when it is missing or damaged, and never one that a newer version of the app installed.

The install also places Heeler's extension for Pi in `~/.pi/agent/extensions` and for Oh My Pi in each profile's `agent/extensions` folder, also listed in the sheet. Those programs load it on their own, so no configuration file changes. It does nothing outside a herdr-core Terminal. Inside one it tells the Terminal which session the program is on, for Chat, and Pi releases before 1.1.0 also report their status through it. An Oh My Pi profile you add later gets its extension from **Repair** in the sheet.

Without systemd linger, the Helper stops about ten seconds after your last login to the Host ends. The sheet checks it and offers **Turn On Linger**. Some Hosts ask for an administrator instead: the sheet shows the Host's reason, and an administrator can run `loginctl enable-linger <your-user>` there.

**Check.** The Host Helper row shows the Host's state each time you check the Host:

| Row reads | What it means |
| --- | --- |
| **Not Installed** | No Helper on this Host |
| A version | Installed and running. The sheet says when this app carries a newer one |
| A newer version | A newer version of Heeler installed it. Update the app to change it |
| **Damaged** | Files are missing or changed. **Repair** puts them back |
| **Node.js Missing** | The Host has no Node.js, or one too old to run the Helper |
| **Linger Off** | Runs only while you are logged in |
| **Service Failed** | The service stopped and will not start again by itself, for example after Node.js moved. **Repair** sets it up with the Node.js the Host has now |
| **Not Available** | This platform has no Helper |

Native Windows Hosts read **Not Available**, so Agent Notifications (in-app banners included), Live Activity and Usage are not available there yet. macOS Hosts also read **Not Available** in this version, with no install offered.

## Agent Notifications

With the Host Helper running, a herdr-core Host notifies you as any other Host does, with Heeler killed too. Turn notifications on for the Host in **Settings > Notifications**. Heeler writes this device's entry for the Host's session into the Helper's directory, never into a plugin's file, and each device's notifications are encrypted with its own key.

- **Blocked** and **Error** come under the Blocked switch. Error reads as Error, since nothing is waiting for your answer.
- **Done** has its own switch, and is per device. A device gets no Done for a turn it has seen: it had the Agent open as the turn ended, or opened the Agent before the notification was due. To know that, Heeler writes a small file for this device in the Helper's directory, holding only Terminal addresses and turn counts, whenever you open an Agent or a turn ends while it is open. Your other devices still get theirs.
- A Terminal that has no Agent, or whose Agent has given way to a shell, sends nothing. A status that lasts under about five seconds sends nothing either.
- What a core had already reported when the Helper first saw it is not announced.

Turning notifications off, or removing the Host while connected, removes this device's entry and its file from the Host. If you remove a disconnected Host, the entry stays and Heeler says so: reconnect first to stop them.

The switches need the Helper, so **Settings > Notifications** says what the Host's Helper needs, such as **Not Installed**, **Service Failed** or **Node.js Missing**. Fix that from the Host's page in **Hosts**. A device already registered keeps its switches there, so it can still leave. With **Linger Off**, the switches work and a note says the Helper stops about ten seconds after your last login ends, so notifications stop too. Notifications need Host Helper 0.4.0 or newer.

### Banners and Live Activity

Once this device is registered with a Host's Helper, that Host's Agents join the in-app banners and the Live Activity alongside your other Hosts. A Host without the Helper, or without this device's registration, gets neither.

- **Banners** come while Heeler is open, under the same switches: Blocked and Error under the Blocked switch, Error reading as Error, and Done under its own switch. Done is this device's, so an Agent you have open makes no Done banner.
- **Live Activity** has its own switch for the Host, and needs Host Helper 0.5.0 or newer. Heeler starts the activity and writes its push token into the Helper's directory. After Heeler suspends, the Helper updates and ends it through the Push Relay. Done counts for this device only, and an Error Agent counts under Blocked, as the Live Activity has no count of its own for it.

While Heeler is suspended the activity names each Agent's workspace by its folder, not a desktop app's space name, and a row field for the Tab or Pane stays empty. Opening Heeler brings those back.

## Usage

With the Helper installed, a core Host's Usage works as on any other Host, in the Usage tab, the Host's detail and the widgets: Token Usage for Claude Code and Codex, and Claude Code's Usage Limits when you turn them on for that Host.

The **Default Account** follows the core, not your SSH login. A core usually starts from the desktop or a login shell, with an environment SSH never sees, so the Helper reads the variables that locate Accounts, such as `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, from the core process. It reads those by name and nothing else, keeps them in a file only your account can read, and reads them again whenever the core restarts. Change `CLAUDE_CONFIG_DIR` and restart the core to move the Default Account.

To count more Claude Code sign-ins, open **Claude Code Accounts**. Heeler suggests the directories of the Claude Code Agents running in the core and those it finds in your home folder. Your choices stay in the Helper's directory, so **Remove** deletes them with it.

| Usage reads | What to do |
| --- | --- |
| **Usage needs the Host Helper** | Install it from the Host's detail |
| **Usage needs a newer Host Helper** | Update it from the Host's detail |
| **The Host Helper has not reached this session's core yet** | Start the core if it is not running. Heeler keeps checking, and the Helper never starts one |
| **Usage comes with the Host Helper, which is not available on native Windows yet** | Nothing for now |

Usage reaches the Helper over its own SSH connection when the Host's session has none, so these read the same whether the core is running or not. **Not connected** in the Usage tab and the widgets means SSH itself could not reach the Host.

The Usage widgets say the same in a shorter form, such as **Needs the Host Helper**. With a widget installed, Heeler checks each core Host when you open the app, so you do not have to open Usage for the widget to catch up.

**Remove.** In the sheet, tap **Remove**. Heeler disables and stops the service, deletes the files the install recorded, the Pi and Oh My Pi extensions among them, then the folders it created that are now empty, and finally the Helper's directory with its notification registrations and seen marks. Removal leaves systemd linger and the Grok Build edit (`program_status` in its configuration) as they are: change those yourself if you no longer want them.
