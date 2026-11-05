# Connect herdr-core

Agents in the Herdr desktop app belong to `herdr-core`, a server separate from Herdr TUI (`herdr`), so each server is its own Host in Heeler even under one SSH account. Most people run `herdr-core` with the Herdr desktop app on a Mac; Heeler also connects to Linux `herdr-core` and [native Windows](#native-windows) `herdr-core.exe`.

## Add a Host

Heeler never starts a core when connecting or checking. Start the Herdr desktop app or `herdr-core` first.

### 1. Enter the SSH settings

1. In **Hosts**, tap **Add Host** (or **Add Manually** when empty). A Pairing Code always adds a Herdr TUI Host.
2. Enter your SSH **User**, add a Route, and pick **Device Key** (`~/.ssh/authorized_keys`), **RSA Key**, or **Password**.
3. Set **Session name** if needed, then tap **Save** and **Trust** after checking the Host's key fingerprint.

| Field | Value |
| --- | --- |
| **Session name** | Blank for `default`, or the core's `HC_SESSION` name |

### 2. Confirm the Server Kind

Heeler checks once without starting anything, then asks you to confirm **Server Kind**:

- Tap **Use herdr-core** when `herdr-core` is found.
- If both `herdr-core` and Herdr TUI are found (or neither runs yet), confirm **Use herdr-core** here and add the machine again for **Use Herdr TUI**.

Once confirmed, **Server Kind** is fixed for that Host entry.

**It worked if** Host detail shows **Server Kind** as `herdr-core` with the server version and `herdr-core running` passing.

## When it does not connect

While the core is stopped, Heeler rechecks on its own, or you can tap **Run Checks Again**:

| Host reads | What to do |
| --- | --- |
| **herdr-core is not running** | Start the Herdr desktop app or `herdr-core`, or check **Session**. If a crash left a socket file, start the core or enable stream-local forwarding in `sshd_config`. |
| **herdr-core is not installed** | Install `herdr-core` on the SSH `PATH`, at `~/.local/bin/herdr-core`, or via its Windows installer, then tap **Run Checks Again**. |
| **herdr-core needs an update** | Run the update command in Host detail, then tap **Run Checks Again**. |
| **The SSH server refuses socket forwarding** | Set `AllowStreamLocalForwarding yes` in `sshd_config`, reload `sshd`, and tap **Run Checks Again**. |
| **The herdr-core socket path is too long** | Use a shorter session name or socket path. |

On Linux when the core is stopped, tap **Start herdr-core** under the checks and confirm **Start** to launch the session via your login shell and turn on `systemd` linger; on macOS and Windows, Host detail shows the command to run there.

## The Console

When the core belongs to the Herdr desktop app, Heeler follows its spaces and tabs:

- **Desktop spaces and tabs:** Each desktop space is a Workspace card in the desktop app's order, with tabs labeled **Tab “name”** or **Tab N**.
- **Other Terminals:** A child Terminal joins its parent's card; other Terminals without a desktop space group by git checkout or launch folder.
- **Agents and Terminals:** Coding Agents and non-shell programs reporting status appear in **Agents**; shells stay in **Terminals**.

| Status | What it means |
| --- | --- |
| **Working** / **Idle** | Running a turn (**Working**) or ready at its prompt (**Idle**). |
| **Blocked** / **Error** | Waiting for your answer (**Blocked**) or reporting an error (**Error**, sorted with **Blocked**). |
| **Done** | Per device: finished a turn while closed here; opening the Agent clears **Done** on this device only. |
| **Unknown** | No status reported yet. Tap **Unknown** to see why; on Grok Build on macOS/Linux, tap **Turn On Grok Build's Status** and **Apply This Change** to set `program_status = "on"` in `~/.grok/config.toml` (undo via **Undo** or **Harness Edits**). |

On macOS/Linux while the Herdr desktop app runs, open an Agent's Composer **More** menu (next to **Add**) and tap **Rename Workspace** to rename that space in both apps.

## Starting things

- **New Agent:** Tap **New Agent**, choose a Workspace, and pick an Agent from your login shell's `PATH` (or a **Preset** from **Settings > Agents & Accounts**). Heeler passes a session flag where supported (and `--no-daemon` for Codex) unless your arguments already set one.
- **New Terminal:** Tap **New Terminal** to open a login shell; in a desktop space, it opens as a new tab in both apps.
- **New Workspace:** Choose **New Workspace** (or **Browse Directory…**); on macOS/Linux with the desktop app running, **Workspace name (optional)** names the space.
- **Templates:** Roles in `~/.config/herdr-core/templates` (or `$XDG_CONFIG_HOME/herdr-core/templates`) appear under **Templates** in **New Agent** and run their command directly.
- **Worktrees:** On macOS/Linux, turn on **Start in a new worktree** in **New Agent** and enter a **Branch** to check out `~/.herdr/worktrees/<repository>/<branch>` as a new Workspace. Remove it via **More > Worktree Details > Remove Worktree**.

> [!NOTE]
> If `herdr-core` inherited variables (`CLAUDECODE`, `TMUX`, `HERDR_PANE_ID`), Host detail shows **Core Environment** naming each variable and its effect; restart the core from a clean terminal to clear them.

## Working with an Agent

All live terminals share the Host's connection, and any viewer can type without a Take Over step. Use Direct Input or the Composer:

- **Send and Stop:** **Send** pastes your draft and submits only if the same Agent still holds the terminal. While **Working** with an empty draft, **Send** becomes **Stop** (on Grok Build, press **Control-C** via Direct Input or the tools keyboard).
- **Add:** Tap **Add** in the Composer (or **Add Image** / **Add File** under **More** in Direct Input) to upload a file and insert its path.
- **Close:** Closing a Tab or Pane ends its Terminal process.

If **Send** or **Stop** cannot finish cleanly, the Composer keeps your draft and shows a notice:

| Notice | What to do |
| --- | --- |
| **stayed in the Agent's input unsubmitted** / **may still be in the Agent's input** | Check the terminal and submit or clear any text before sending again. |
| **no longer in the terminal** / **may still be in the terminal** | The Agent exited before submit; check the terminal first. |
| **not accepting a paste** / **keeps a shell open** | Wait for the prompt, or use Direct Input (required on Windows when a shell stays open after exit). |
| **waiting on its question on screen** / **still shows Working** / **may or may not have reached the Agent** | Answer the **Blocked** prompt first, or check the terminal and tap **Stop** again. |

## Chat

In **Chat**, you can read an Agent's conversation, send messages, stop a turn, and answer **Blocked** prompts with buttons:

| Program | Session notes |
| --- | --- |
| Claude Code (`claude`) | Opens on macOS, Linux, Windows; binds at the prompt and follows `/clear` and `/resume`. |
| Codex (`codex`) | Opens on macOS, Linux; binds on first message when started with `--no-daemon`. |
| Grok Build (`grok`) | Opens on macOS, Linux, Windows; binds while one conversation is active (after `/new`, restart or choose on macOS/Linux). |
| Pi (`pi`), Oh My Pi (`omp`) | Opens on macOS, Linux, Windows (with extension); exact with the [Host Helper](#host-helper) or Windows extension, or binds by process/title on macOS/Linux. |
| OpenCode (`opencode`) | Terminal only (off for `herdr-core` Hosts). |

- **Can't Tell the Conversation:** When Chat cannot prove the transcript, it shows **Can't Tell the Conversation** with the fix and **Check Again**. On macOS/Linux, tap **Choose a Conversation**, preview a transcript, and tap **Use This Conversation**.
- **Pi and Oh My Pi on Windows:** Tap **Add Heeler's Extension…** in Chat, review `.pi\agent\extensions`, `.omp\agent\extensions`, and Oh My Pi profile folders, tap **Add to … Folders** (`heeler-session.js`), and restart the Agent.

## Host Helper

On Linux and macOS, the **Host Helper** is Heeler's Node.js service (`systemd --user` on Linux, `launchd` LaunchAgent on macOS). It follows `herdr-core` without starting a core and adds **Agent Notifications** (**Settings > Notifications**), in-app **Banners**, **Live Activity**, **Usage** (**Token Usage**, **Usage Limits**, and widgets), and Heeler's session extension for **Pi** and **Oh My Pi**.

### 1. Review the files

1. Open the Host in **Hosts** and tap **Host Helper**.
2. Review **Files This Writes** (`~/.local/share/heeler/host-helper` on Linux or `~/Library/Application Support/heeler/host-helper` on macOS, the user service file, and Pi/Oh My Pi `agent/extensions` folders).

### 2. Install the Helper

1. Tap **Install**.
2. On Linux, if **Systemd Linger** is offered, tap **Turn On Linger** (`sudo loginctl enable-linger <user>`) so the Helper stays running after logout.

**It worked if** the **Host Helper** row shows the installed version and the sheet reads **The Host Helper is running.**

| Row reads | What it means |
| --- | --- |
| **Not Installed** / version (`0.5.4`) | Tap **Install**, or tap **Update** when a newer version is bundled. |
| **Damaged** / **Node.js Moved** / **Service Failed** | Files changed, Node.js moved, or the service stopped; tap **Repair**. |
| **Node.js Missing** / **Linger Off** / **Not Available** | Install Node.js 22+ and tap **Run Checks Again**, tap **Turn On Linger**, or note that Windows (and Linux without `systemd`) has no Host Helper. |

To uninstall, open **Host Helper** and tap **Remove** to stop the service and delete its files, Pi/Oh My Pi extensions, and Helper directory (including notification registrations).

## Native Windows

Add a Windows machine over OpenSSH (`sshd`):

- **Location and start:** Heeler looks for `%LOCALAPPDATA%\Programs\herdr-core\herdr-core.exe` and connects only when its named pipe exists. Start the core in a non-administrator PowerShell window in your desktop session using the command in Host detail.
- **What works:** Workspaces and statuses, live terminals, **New Terminal**, **New Agent** (via Windows PowerShell), **New Workspace** (folder-named until the desktop app names it), Composer **Send**, **Stop**, and **Add** (up to 8 MiB per file in `%LOCALAPPDATA%\herdr-core\<session>\files\<terminal>\`), and **Chat** for Claude Code, Grok Build, Pi, and Oh My Pi.
- **Not offered on Windows:** **Rename Workspace**, **Worktrees**, **Changes**, **Skills**, **Choose a Conversation**, automatic harness config edits, and **Host Helper** (**Not Available**).

## Known limits

- **No Agent rename:** Agents cannot be renamed on a `herdr-core` Host; Workspaces rename only via a running Herdr desktop app on macOS/Linux.
- **OpenCode Chat is off:** OpenCode Agents offer the terminal only.
- **In-process `/new` without hooks:** After `/new` in Codex, use the terminal until you exit and run `codex resume --no-daemon`; on Pi without the Host Helper, `/new` is noticed only after a Chat message fails to appear in the old transcript.
- **Federated Terminals:** Omitted; add the other machine as its own Host.
- **First-time `zsh` without `~/.zshrc`:** `zsh` opens its wizard and a new Agent waits until you finish it or create `~/.zshrc`.

Last checked on 2026-11-06 against herdr-core 0.1.18 and the Herdr desktop app 0.1.13.
