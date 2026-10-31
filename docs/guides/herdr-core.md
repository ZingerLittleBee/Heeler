# Connect herdr-app / herdr-core

Agents started by the desktop herdr-app belong to herdr-core. They do not appear in the legacy herdr TUI server, even when both servers run under the same SSH account. Add a separate Host for each backend you want to use.

1. Install `hc` (or `herdr-core`) on the Host and start herdr-app. Heeler supports the generation-one API. The compatibility observations cover herdr-core 0.1.13 and herdr-app 0.1.7; the app and core have separate version numbers.
2. In Heeler, choose **Add Host**, enter the SSH account and Route, and choose **herdr-app / herdr-core** under **Backend**.
3. Use Device Key, RSA Key, or Password authentication. For a Device Key, copy the form's public-key line into the Host's `~/.ssh/authorized_keys`. The private key stays on the phone. The TUI plugin's Pairing Code does not select core.
4. Leave Session blank for `default`, or enter the desktop core's `HC_SESSION` name. Test the connection and open the Console.

Heeler runs `hc connect` and `hc attach` over SSH, verifying the core executable in the usual user-local and package-manager locations. Each command selects `HC_SESSION` and clears inherited terminal/socket overrides; it never falls back to legacy herdr. Core resolves its own socket, including `/run/user/<uid>/herdr-core/default.sock` on Linux when the SSH login has no `XDG_RUNTIME_DIR`. A custom installation can provide a core-compatible launcher on the SSH account's PATH that selects its configuration and runtime directories.

`hc connect` can start core if the selected session is not running. A mistyped session can therefore connect successfully to a new, empty core. If Agents is empty, compare `hc ls` in the desktop's session with `HC_SESSION=default hc ls` through the same SSH account, substituting the selected session name when needed. A successful connection alone does not establish that Heeler found the desktop's session.

Recognized coding programs appear in Agents; ordinary shells and other programs appear in Terminals. A custom reported program name does not by itself add Agent support. Status comes from the program's core report, so an unreported program remains Unknown; Error keeps its own wording and asks for attention. A confirmed foreground shell removes an exited Agent despite its retained status report.

Terminals labeled by the desktop app show under its spaces and tabs, and the rest are grouped by the directory they first launched in. Live attachment supports input and resize. Closing a terminal ends its program on the desktop too.

Composer's **Insert into Terminal** action accepts one line without control characters. It inserts that line into the already connected live terminal without Enter. Check the terminal and press Enter yourself when ready to submit. Multiline or control-containing drafts stay local; copy multiline text and use the Terminal's reviewed **Paste** action. If the live terminal is unavailable, connect it before inserting. Core's queued send API cannot bind a submission to the same Agent process, so Heeler does not use it for automatic submission.

Console previews read the current screen without scrolling the remote program. When an action may have reached core but no reply confirms it, Heeler reports that the outcome is unknown and does not automatically repeat it. Check the terminal before trying again.

The core CLI reserves its configured detach chord, **Ctrl+backslash** by default. Sending that chord closes the attachment instead of delivering it, and may discard later bytes in the same input chunk. A Host configured to detach on Ctrl+C also reserves the ordinary interrupt key. Reconnect to continue; the underlying program keeps running. Heeler does not override this core configuration.

Chat, the Heeler plugin, notifications, Live Activities, renaming, and creating/removing Worktrees are unavailable for this backend. Usage comes through the [Host Helper](#usage). Core does not supply the legacy plugin contract or exact transcript identity. Changes, files, and Skills still use the same Host's SSH filesystem. Terminals federated from another machine are omitted: add that machine directly as a Host so its file operations reach the right computer.

Existing legacy Hosts stay on herdr. A manually configured Host can be edited or duplicated to select core. Before switching a legacy Host, turn off its notifications and wait for the remote update to finish; an unreachable original Host must be recovered before that registration can be removed. Hosts carrying a paired Herdr Endpoint retain that endpoint when edited or duplicated and cannot change backend. Add a new manual core Host for those accounts.

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
