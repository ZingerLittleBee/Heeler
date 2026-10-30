# Connect herdr-app / herdr-core

Agents started by the desktop herdr-app belong to herdr-core. They do not appear in the legacy herdr TUI server, even when both servers run under the same SSH account. Add a separate Host for each backend you want to use.

1. Install `hc` (or `herdr-core`) on the Host and start herdr-app. Heeler supports the generation-one API. The compatibility observations cover herdr-core 0.1.13 and herdr-app 0.1.7; the app and core have separate version numbers.
2. In Heeler, choose **Add Host**, enter the SSH account and Route, and choose **herdr-app / herdr-core** under **Backend**.
3. Use Device Key, RSA Key, or Password authentication. For a Device Key, copy the form's public-key line into the Host's `~/.ssh/authorized_keys`. The private key stays on the phone. The TUI plugin's Pairing Code does not select core.
4. Leave Session blank for `default`, or enter the desktop core's `HC_SESSION` name. Test the connection and open the Console.

Heeler runs `hc connect` and `hc attach` over SSH, verifying the core executable in the usual user-local and package-manager locations. Each command selects `HC_SESSION` and clears inherited terminal/socket overrides; it never falls back to legacy herdr. Core resolves its own socket, including `/run/user/<uid>/herdr-core/default.sock` on Linux when the SSH login has no `XDG_RUNTIME_DIR`. A custom installation can provide a core-compatible launcher on the SSH account's PATH that selects its configuration and runtime directories.

`hc connect` can start core if the selected session is not running. A mistyped session can therefore connect successfully to a new, empty core. If Agents is empty, compare `hc ls` in the desktop's session with `HC_SESSION=default hc ls` through the same SSH account, substituting the selected session name when needed. A successful connection alone does not establish that Heeler found the desktop's session.

Recognized coding programs appear in Agents; ordinary shells and other programs appear in Terminals. A custom reported program name does not by itself add Agent support. Status comes from the program's core report, so an unreported program remains Unknown; Error keeps its own wording and asks for attention. A confirmed foreground shell removes an exited Agent despite its retained status report.

Terminals are grouped by their launch directory, independently of the desktop's layout. Live attachment supports input and resize. You can start Agents and open or close terminals in an existing or new directory. A terminal created from Heeler is not automatically placed in the desktop layout: adopt it there when you want it in a desktop pane. Closing it ends its program on the desktop too.

Composer's **Insert into Terminal** action accepts one line without control characters. It inserts that line into the already connected live terminal without Enter. Check the terminal and press Enter yourself when ready to submit. Multiline or control-containing drafts stay local; copy multiline text and use the Terminal's reviewed **Paste** action. If the live terminal is unavailable, connect it before inserting. Core's queued send API cannot bind a submission to the same Agent process, so Heeler does not use it for automatic submission.

Console previews read the current screen without scrolling the remote program. When an action may have reached core but no reply confirms it, Heeler reports that the outcome is unknown and does not automatically repeat it. Check the terminal before trying again.

The core CLI reserves its configured detach chord, **Ctrl+backslash** by default. Sending that chord closes the attachment instead of delivering it, and may discard later bytes in the same input chunk. A Host configured to detach on Ctrl+C also reserves the ordinary interrupt key. Reconnect to continue; the underlying program keeps running. Heeler does not override this core configuration.

Chat, the Heeler plugin, notifications, Live Activities, Usage, renaming, and creating/removing Worktrees are unavailable for this backend. Core does not supply the legacy plugin contract or exact transcript identity. Changes, files, and Skills still use the same Host's SSH filesystem. Terminals federated from another machine are omitted: add that machine directly as a Host so its file operations reach the right computer.

Existing legacy Hosts stay on herdr. A manually configured Host can be edited or duplicated to select core. Before switching a legacy Host, turn off its notifications and wait for the remote update to finish; an unreachable original Host must be recovered before that registration can be removed. Hosts carrying a paired Herdr Endpoint retain that endpoint when edited or duplicated and cannot change backend. Add a new manual core Host for those accounts.
