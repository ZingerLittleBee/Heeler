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

A row opens the Agent's detail. Its menu has Open in New Window where the device has windows, and no Close.

**Agent List Fields** in Settings sets a core Host's rows, starting from Heeler's own fields. It offers the labels of the Host's Terminals, and no Sync from plugin, since no plugin runs there.

**Pins** are per Host and survive a core restart. A Pin goes when its Terminal is removed, and all of a Host's Pins go when its core was wiped and started new.

## Terminal

Every terminal is a channel on the Host's one connection, so opening more costs no new SSH session. It is one of any number of viewers: the desktop can stay attached, typing takes the size, and no Take Over appears. Scrollback comes with it. Up to five terminals stay ready for five minutes after you leave them, and come back at once.

Every key reaches the program, Ctrl+\ included. Heeler reserves no detach key.

In an Agent detail, Direct Input types into the terminal, and Changes and Skills work as on any other Host.

## Images and files

On a macOS or Linux Host, **Add** in the Composer, or **Add Image** and **Add File** under More in Direct Input, stages an image or file as on any other Host. Heeler uploads it over SFTP, puts its path on the Host in your draft, and copies the path. Nothing reaches the Agent yet: the draft waits, and since a core Host has no Send yet, paste the path into the terminal to use it.

Add appears once the connection has told Heeler the Host's platform, a moment after the detail opens. Native Windows core Hosts do not offer it yet.

## Restarts and ended Terminals

| What happened | Heeler shows |
| --- | --- |
| A kept Terminal lost its program, for example to a crash or a signal | **Restarting…** The core brings the Terminal back as a new shell at the same address, and an open terminal reattaches by itself, with no error and nothing to tap. An Agent detail stays open over the new shell |
| A program exited, including your own `exit` | **Agent Ended** in an Agent detail, or **Terminal Closed** on a Terminal's own screen. The Terminal has ended for good, so nothing reattaches |

The new shell is no Agent until you start one in it.

## Core Environment

A core started from inside another program can inherit variables that change how its programs behave. Host detail then shows **Core Environment**, naming each variable and what it breaks, never its value. Restarting the core from your own terminal fixes it. Heeler does not restart it.

## New Agent and New Terminal

**New Agent** lists the agents your own shell can run, and starts the one you pick through that shell, so it has the `PATH` and variables your startup files set. That shell is your login shell on the Host, bash, zsh and fish alike. Arguments you type stay whole, however many spaces, quotes or `$` they hold.

Pick where it starts, for an Agent and for **New Terminal** alike:

| You pick | It starts | It shows |
| --- | --- | --- |
| A desktop space | In the directory of the Agent you started from, else the space's folder | In a new tab of that space, here and in the desktop app |
| A directory's Workspace | In that Workspace's directory, even after a Terminal in it moved elsewhere | In that Workspace, and not in the desktop app's layout until you adopt it there |
| **Browse Directory…** | In the directory you chose | In a Workspace named for that directory |

Heeler asks for no tab or Workspace name on this kind of Host. Worktrees and Templates are not offered here yet.

Heeler gives an Agent a session of its own from the start where the program takes one, unless your arguments already pick a session, as `--resume` does. Codex runs with `--no-daemon`. OpenCode gets its session only from version 2.1.

If the Host does not confirm a start, Heeler says so and does not try again, since the Agent may already be running. Check the Host before starting another.

**Known limit:** with zsh as your login shell and no startup files, such as no `~/.zshrc`, zsh opens its new-user wizard and the Agent waits behind it. Open the Terminal and answer the wizard once, or create an empty `~/.zshrc` on the Host first.

## Known limits

- Heeler has no Close or Rename on a core Host yet. Use the Host or the desktop.
- Worktrees and Chat are not available yet.
- An Agent detail's Send and Stop stay hidden. Use Direct Input to type into the terminal.
- Notifications and Live Activities are not available yet.
- Terminals federated from another machine are omitted. Add that machine as a Host of its own, so its file operations reach the right computer.
- If the connection drops while an Agent detail is open on a Terminal that lost its program or ended, the detail reads **Agent Gone** after the reconnect. A restored Terminal has its row in the Terminals tab.

## Host Helper

The Host Helper is Heeler's own background service on a herdr-core Host. It stands in for the Heeler plugin, which core cannot run, and it runs on the Host's Node.js. It follows the core and answers Usage. Notifications and Live Activities still read as unavailable until the app connects them to it.

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
