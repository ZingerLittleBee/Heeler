# Connect herdr-app / herdr-core

Agents started by the desktop herdr-app belong to herdr-core. They do not appear in the legacy herdr TUI server, even when both servers run under the same SSH account. Add a separate Host for each backend you want to use.

1. Install `hc` (or `herdr-core`) on the Host and start herdr-app. The generation-one API is supported; verification used herdr-core 0.1.13. herdr-app 0.1.7 uses this API too; its app version is separate from the core version.
2. In Heeler, choose **Add Host**, enter the SSH account and Route, and choose **herdr-app / herdr-core** under **Backend**.
3. Use Device Key, RSA Key, or Password authentication. For a Device Key, copy the form's public-key line into the Host's `~/.ssh/authorized_keys`. The private key stays on the phone. The TUI plugin's Pairing Code does not select core.
4. Leave Session blank for `default`, or enter the desktop core's `HC_SESSION` name. Test the connection and open the Console.

Heeler runs `hc connect` and `hc attach` over SSH, finding either executable in the usual user-local and package-manager locations. It sets `HC_SESSION` for every command and clears inherited terminal/socket overrides; it never falls back to legacy herdr. Core resolves its own socket, including `/run/user/<uid>/herdr-core/default.sock` on Linux when the SSH login has no `XDG_RUNTIME_DIR`. A custom installation can provide an `hc` launcher on the SSH account's PATH that selects its configuration and runtime directories.

Recognized coding programs appear in Agents; ordinary shells and other programs appear in Terminals. Status comes from the program's core status report, so a program that does not report status remains Unknown. Terminals are grouped by their launch directory, independently of the desktop's layout. Live attachment supports input and resize, Composer sends text and control keys, and you can open or close terminals and start Agents in an existing or new directory. Closing a terminal ends its program on the desktop too.

Chat, the Heeler plugin, notifications, Live Activities, Usage, renaming, and creating/removing Worktrees are unavailable for this backend. Core does not supply the legacy plugin contract or exact transcript identity. Changes, files, and Skills still use the same Host's SSH filesystem. Terminals federated from another machine are omitted: add that machine directly as a Host so its file operations reach the right computer.

If Agents is empty, compare `hc ls` in the desktop's session with `HC_SESSION=default hc ls` through the same SSH account. Check the session and program identity before moving agents. Existing legacy Hosts stay on herdr; edit or duplicate one to select the core backend explicitly.
