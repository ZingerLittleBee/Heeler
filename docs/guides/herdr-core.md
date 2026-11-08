# Connect herdr-core

Agents in the Herdr desktop app belong to herdr-core, a server separate from Herdr TUI. Each server is its own Host in Heeler even under one SSH account. Most people run herdr-core with the Herdr desktop app on a Mac, and Heeler also connects to Linux herdr-core and [native Windows](#native-windows) `herdr-core.exe`.

## Before you start

- Remote Login turned on for the Mac and its SSH fingerprint noted: [Prepare the Host](overlay-networks.md#prepare-the-host). On Linux, run OpenSSH. On Windows, follow [Windows setup](windows-setup.md).
- The Herdr desktop app running on the Mac, or herdr-core running on Linux or [native Windows](#native-windows).
- A way for your phone to reach the Mac: directly on the same network, or over an [overlay network](overlay-networks.md). A Host can have [multiple routes](host-routes.md).

## Add a Host

Heeler never starts a core when connecting or checking. Start the Herdr desktop app or herdr-core first.

### 1. Enter the SSH settings

1. In **Hosts**, tap **Add Host**, or **Add Manually** when empty. A Pairing Code always adds a Herdr TUI Host.
2. Enter your SSH **User**, add a Route, and pick **Device Key**, **RSA Key**, or **Password**.
3. For **Device Key**, copy the form's public-key line into the Host's `~/.ssh/authorized_keys`.
4. Set **Session name** if needed, then tap **Save** and **Trust** after checking the Host's key fingerprint.

| Field | Value |
| --- | --- |
| **Session name** | Blank for `default`, or the core's `HC_SESSION` name |

### 2. Confirm the Server Kind

Heeler checks once without starting anything, then asks you to confirm **Server Kind**:

| Heeler found | What to do |
| --- | --- |
| herdr-core | Tap **Use herdr-core**. |
| Both herdr-core and Herdr TUI | Confirm one here, then add the machine again for the other. |
| Neither | Confirm the kind you will run. Its checks then say how to set it up. |

Once confirmed, **Server Kind** is fixed.

**It worked if** Host detail shows **Server Kind** as herdr-core with the version and **herdr-core running** passing.

## When it does not connect

While the core is stopped, Heeler rechecks on its own, or you can tap **Run Checks Again**:

| Host reads | What to do |
| --- | --- |
| **herdr-core is not running** | Start the Herdr desktop app or herdr-core, or check **Session name**. If a crash left a socket file, start the core or allow stream-local forwarding. |
| **herdr-core is not installed** | Install herdr-core on the SSH `PATH`, at `~/.local/bin/herdr-core`, or with its Windows installer, then tap **Run Checks Again**. |
| **herdr-core needs an update** | Run the update command in Host detail, then tap **Run Checks Again**. |
| **The SSH server refuses socket forwarding** | Set `AllowStreamLocalForwarding yes` in `sshd_config`, reload `sshd`, and tap **Run Checks Again**. |
| **The herdr-core socket path is too long** | Use a shorter **Session name** or socket path. |

On Linux when the core is stopped, tap **Start herdr-core** under the checks and confirm **Start** to launch the session via your login shell and turn on systemd linger. On macOS and Windows, Host detail shows the command to run there.

## The Console

When the core belongs to the Herdr desktop app, Heeler follows its spaces and tabs:

- **Desktop spaces and tabs:** Each desktop space is a Workspace card in the desktop app's order, with tabs labeled **Tab “name”** or **Tab N**.
- **Other Terminals:** A child Terminal joins its parent's card. Other Terminals group by git checkout or launch folder.
- **Agents and Terminals:** Coding Agents and non-shell programs reporting status appear in **Agents**. Shells stay in **Terminals**.

| Status | What it means |
| --- | --- |
| **Working** | Running a turn. |
| **Idle** | Waiting at its prompt. |
| **Blocked** | Waiting for your answer. |
| **Error** | Reported an error and sorts with **Blocked**. |
| **Done** | Finished a turn while closed here. Opening the Agent clears **Done** on this device only. |
| **Unknown** | No status reported yet. Tap **Unknown** to see why. |

On macOS and Linux, when Grok Build shows **Unknown**, tap **Turn On Grok Build's Status** and **Apply This Change** to set `program_status = "on"` in `$GROK_HOME/config.toml` or `~/.grok/config.toml`. Revert it with **Undo** or under **Harness Edits** in Host detail.

On macOS and Linux while the desktop app runs, tap **Rename Workspace** in an Agent's Composer **More** menu to rename that space in both apps.

## Starting things

- **New Agent:** Tap **New Agent**, choose a Workspace, and pick an Agent from your login shell's `PATH` or a **Preset** from **Settings > Agents & Accounts**. Heeler passes a session flag where supported and starts Codex with `--no-daemon`, unless your arguments set a session.
- **New Terminal:** Opens a Terminal in the shell the core runs, adding a tab in a desktop space.
- **New Workspace:** Choose **New Workspace** or **Browse Directory…**. On macOS and Linux while the desktop app runs, **Workspace name (optional)** names the space.
- **Templates:** Roles in `~/.config/herdr-core/templates` or `$XDG_CONFIG_HOME/herdr-core/templates` appear under **Templates** in **New Agent** and run their command directly.
- **Worktrees:** On macOS and Linux, turn on **Start in a new worktree** in **New Agent** and enter a **Branch** to check out `~/.herdr/worktrees/<repository>/<branch>`. To remove it, tap **More > Worktree Details > Remove Worktree**. Heeler ends every Terminal of that Workspace first, then removes the checkout.

> [!NOTE]
> If herdr-core inherited variables such as `CLAUDECODE` or `TMUX`, Host detail shows **Core Environment** naming each variable and its effect. Restart the core from a clean terminal to clear them.

## Working with an Agent

Live terminals share the Host's connection, and any viewer can type without a Take Over step. Use Direct Input or the Composer:

- **Send and Stop:** **Send** pastes your draft and presses Enter only if the same Agent still holds the terminal. While **Working** with an empty draft, **Send** becomes **Stop**. On Grok Build, press **Control-C** with Direct Input or the tools keyboard.
- **Add:** Tap **Add** in the Composer, or **Add Image** or **Add File** under **More** in Direct Input, to upload a file and insert its path.
- **Close:** Closing a Tab or Pane ends its Terminal.

If the Host does not answer a Send step, Heeler never sends the message again and offers **Edit Draft** so you can check the terminal first. When **Send** or **Stop** cannot finish cleanly, the Composer keeps your draft and shows a notice:

| Notice | What to do |
| --- | --- |
| **stayed in the Agent's input unsubmitted** | Submit or clear the text in the terminal before sending again. |
| **may still be in the terminal** | The Agent exited before submit. Check the terminal first. |
| **not accepting a paste** | Wait for the prompt, or type with Direct Input. |
| **waiting on its question on screen** | Answer the **Blocked** prompt first, then send again. |
| **still shows Working** | Tap **Stop** again if you still want it to stop. |
| **may or may not have reached the Agent** | Heeler does not resend **Stop**. Look at the terminal first. |

## Chat

In **Chat**, you can read conversations, send messages, stop a turn, and answer **Blocked** prompts with buttons:

| Program | Session notes |
| --- | --- |
| Claude Code | Opens on macOS, Linux, and Windows. Binds at its prompt and follows `/clear` and `/resume`. |
| Codex | Opens on macOS and Linux. Binds on the first message when started with `--no-daemon`. |
| Grok Build | Opens on macOS, Linux, and Windows. Binds while Grok Build's process lists one conversation. After `/new`, restart or use **Choose a Conversation** on macOS and Linux. |
| Pi | Opens on macOS, Linux, and Windows. Binds with the [Host Helper](#host-helper), on Windows with Heeler's extension, or when Heeler started it. Otherwise use **Choose a Conversation**. |
| Oh My Pi | Opens on macOS, Linux, and Windows. Binds with the [Host Helper](#host-helper), on Windows with Heeler's extension, or once the first message makes it hold its session file. Otherwise use **Choose a Conversation**. |
| Antigravity CLI | Opens on macOS. Binds after you send the first message in the terminal, and follows `/clear`. |
| OpenCode | Off for herdr-core Hosts. Offers the terminal only. |

- **Can't Tell the Conversation:** When Chat cannot prove the conversation, it shows **Can't Tell the Conversation** with the fix and **Check Again**. On macOS and Linux, tap **Choose a Conversation**, preview a conversation, and tap **Use This Conversation**.
- **Pi and Oh My Pi on Windows:** In Chat, tap **Add Heeler's Extension…** to review `.pi\agent\extensions`, `.omp\agent\extensions`, and Oh My Pi profile folders, tap **Add to … Folders** to write `heeler-session.js`, and restart the Agent.

## Host Helper

Connecting and everyday use do not need the Host Helper. Install it on macOS or Linux for **Agent Notifications**, in-app banners, **Live Activity**, **Usage**, and exact **Pi** and **Oh My Pi** Chat.

The Host Helper runs on the Host's Node.js as a `systemd` user service on Linux or a `launchd` LaunchAgent on macOS, following herdr-core without starting a core.

### 1. Review the files

1. Open the Host in **Hosts** and tap **Host Helper**.
2. Review **Files This Writes**: `~/.local/share/heeler/host-helper` on Linux or `~/Library/Application Support/heeler/host-helper` on macOS, the service file, and Pi and Oh My Pi `agent/extensions` folders.

### 2. Install the Helper

1. Tap **Install**.
2. On Linux, if **Systemd Linger** appears, tap **Turn On Linger** to keep the Helper running after logout. The button runs `loginctl --no-ask-password enable-linger` without `sudo`. When the Host refuses, the sheet shows `sudo loginctl enable-linger <user>` for an administrator.

**It worked if** the **Host Helper** row shows the installed version and the sheet reads **The Host Helper is running.**

macOS may notify that `node` can run in the background and list it under Login Items. After a Mac restart, the Helper runs again only once Heeler reads it when Host detail opens or a device that allows notifications connects. On a Mac, Claude Code's Usage Limits may read **need your own login on this Mac**, while Token Usage still counts.

| Row reads | What it means |
| --- | --- |
| **Not Installed** | Tap **Install**. |
| A version | Running. Tap **Update** when a newer version is bundled. |
| **Damaged** | Files changed or missing. Tap **Repair**. |
| **Node.js Missing** | Install a current Node.js, then tap **Run Checks Again**. The row's detail gives the minimum version. |
| **Linger Off** | Stops after logout. Tap **Turn On Linger**. |
| **Node.js Moved** | The service's Node.js moved. Tap **Repair**. |
| **Service Failed** | Stopped or not staying up. Tap **Repair**. |
| **Not Available** | Native Windows and Linux without `systemd` have no Host Helper. |

To uninstall, open **Host Helper** and tap **Remove** to stop the service and delete its files, extensions, and directory.

## Native Windows

Add a Windows machine over OpenSSH:

- **Location and start:** Heeler looks for `%LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe` and connects only when its named pipe exists. Start the core in a non-administrator PowerShell window in your desktop session with the command in Host detail.
- **What works:** Workspaces, statuses, live terminals, **New Terminal**, **New Agent**, and **New Workspace**. **New Agent** runs through Windows PowerShell and reads its profile, not PowerShell 7's. **New Workspace** uses the checkout or folder name until the desktop app names it. Composer **Send**, **Stop**, and **Add** up to 8 MiB per file in `%LOCALAPPDATA%\herdr-core\<session>\files\<terminal>\` work, plus **Chat** for Claude Code, Grok Build, Pi, and Oh My Pi.
- **Not offered on Windows:** **Rename Workspace**, **Worktrees**, **Changes**, **Skills**, **Choose a Conversation**, automatic configuration edits, and **Host Helper**, which reads **Not Available**.

## Known limits

- **No Agent rename:** Agents cannot be renamed on a herdr-core Host. Workspaces rename only via a running Herdr desktop app on macOS and Linux.
- **OpenCode Chat is off:** OpenCode Agents offer the terminal only.
- **Starting a new conversation with `/new`:** After `/new` in Codex, use the terminal until you exit and run `codex resume --no-daemon`. In Pi without the Host Helper, `/new` is noticed only after a Chat message fails to appear in the old conversation.
- **Federated Terminals:** Omitted. Add the other machine as its own Host.
- **First-time `zsh` without `~/.zshrc`:** `zsh` opens its wizard and a new Agent waits until you finish it or create `~/.zshrc`.

Last checked on 2026-11-06 against herdr-core 0.1.18 and the Herdr desktop app 0.1.13.
