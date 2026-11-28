# Rex daily workflows

The reference is Heeler on Herdr TUI 0.9.5, as shipped on origin/main at
`10148154331e5496afaef9b5b450d514fd1d7d8e`. The working tree was clean when
Herdr created the independent `feat/rex-daily-workflows` branch from that
commit. The Xcode project builds Heeler 0.1.18 (43). The test Hosts run Rex
0.1.0-preview.25 (`b070aae645f5`, native API 24). A normal connection on
macOS 27.0.1 (26A434) or Debian 12.15 arm64 selects API 19. The older end of
Heeler's range was exercised by a separately pinned client at API 12.
Herdr TUI reports protocol 22. Xcode 27.2 (27B52) built the iOS 27.0
Simulator app. The [daily acceptance matrix](rex-daily-acceptance.md) records results by Host, backend and running program for the November 27–28, 2026 runs.

The [review handoff](rex-daily-handoff.md) records the exact application and test driver, user entry points, failure dispositions, and screenshots.

## Trace from the user entry

| User entry | Herdr TUI reference | Rex at the base | Candidate implementation and acceptance check |
| --- | --- | --- | --- |
| Hosts → Add Manually → Connect → Servers | Detect, select and check an existing Herdr session. | Detect the account's running Rex and store its socket. Unix SSH and native Windows have different channels. | Server discovery → RexProbe → RexSSHTransport → one RexHostSession per Host. Compare the fingerprint, the selected Server, the negotiated welcome, failed lookup and an SSH forwarding refusal. Host detail shows the last reported kernel, negotiated API and supported Chat programs. |
| Terminals → pull to refresh | Re-read the inventory. | Subscription updates the view. Manual refresh returned without a new Rex read. | RexConsoleProjection waits for RexInventoryFollower to read the active connection again. A reconnect or cancelled waiter cannot acknowledge an old refresh. Compare two observers' active windows, split order, foreground PIDs and detached blocks. |
| Terminals → + or New Terminal Here | Start a shell, optionally name its Tab, optionally create a Workspace. | Rex session/window/terminal block project to Workspace/Tab/Pane. New Terminal worked. The form omitted the window name. | NewTerminalStore → RexNewTerminal → background window or new session. The POSIX Tab field maps to window_label. Compare the returned session view, selected cwd, neighbor/focus and terminal size before, during and after viewing. |
| Agents → + → installed Agent or preset | Start in the chosen directory, with the preset, arguments, environment and account. | No native entry. | StartAgentStore → RexConsoleProjection → shell-flavor schema check → literal argv launch. Check the executable's own argv, PID, environment and cwd against Rex. With no directory override the launch uses the focused terminal in the active window, including the second half of a split. A missing directory refuses execution. No server startup or SSH command per input. |
| New Agent → Start in a new worktree | Create a branch and checkout and open an Agent there. Herdr can also remove and manage a Worktree. | No Rex checkout or launch from the app. | Shared Git gate and checkout service, followed by Rex session creation. Verify branch, HEAD, linked checkout, original dirty files, and neighboring shell PID. If the Agent cannot start, its checkout location remains available. From a neighboring Heeler Terminal after the Agent exits, Git can remove the clean checkout. Verify that the branch, the source checkout’s local changes and the desktop focus survive. Native removal requires safe handling of all programs using that checkout. |
| Terminals → Workspace pencil; Agent menu → Rename Agent | Persistent Workspace and management names. Supported harnesses also offer a separate title command. | Rex read session, window and block labels and the terminal title. Editing was absent. | RenameStore → Rex projection → session.set_label or session.set_block_label. A sheet retains its server and a block edit checks the original foreground. Compare the independent block label, OSC title, session label and neighboring PIDs. Clearing a block's custom name restores its default. Harness conversation-title commands require their own identity and outcome proof. |
| Agent and terminal menus → Close, Move, layout | Close the selected Pane/Tab, move Panes and use the desktop's layout. | The inventory projects Rex's structure. No app mutation. | On preview.25 an unrecognized foreground precondition on block.close was silently ignored; moving a focused block in an inactive window changed the desktop's active window. Cross-session transfer needs revision 22, undo needs 20. Check an explicit shell exit by typing in its visible Terminal and checking neighbors. For an app action, Rex must support an atomic foreground check and focus preservation. [Object probes](rex-object-operations.md) |
| Chat → follow, type, attach, act on a card, Stop | Each harness has its own binding, history, cards and stop keys. | Six POSIX programs had native entries. Evidence varied by harness and feature; older Droid/Devin runs proved some Linux Chat paths. | AgentChatStore and the existing transcript reducers read over SSH. RexChatTyping and RexBlockRequests use the shared control link. A desktop action, a changed foreground or a changed session must invalidate pending input. An Unknown status requires the correct Terminal for Stop and blocked prompts. [Harness inventory](rex-chat-parity.md) · [Droid](droid-chat-validation.md) · [Devin](devin-chat-validation.md) |
| Agent detail → Files, Changes; keyboard → Skills | Read account files, Git patches and installed skills. | Files shared SFTP. The general Host services gate hid Changes and Skills. | Reuse the existing readers through HostProjectReading on POSIX. Check the tracked and untracked patches and the selected skill body. Only explicit reads run. Bulk row totals remain off. |
| Agent detail → Hand Off; GitHub tab; Ports | Prepare a target's draft; read GitHub through the Host's gh; preview a Host loopback service. | These use Host services with their own eligibility gates. A named-pipe Rex Host could offer Ports ahead of a supported reader. | Check the target's draft and both transcripts, a read through the real gh executable, and the visible port with its actual HTTP body. Ports requires a supported Host filesystem and listening-port tool. [Host service paths](rex-host-services-parity.md) |
| Settings → Notifications | The plugin can register encrypted push and Live Activity updates. With consent the active app also presents a banner. | Rex Program Status existed. No user-enabled delivery. | Per-Rex preferences on this device, foreground scene gating, a verified recipient and immediate navigation. Exercise opt-out, duplicate Done, tapping the correct Blocked/Done row and a departed foreground. Suspended delivery needs a persistent listener and registration. |
| Usage, Home Screen widgets and Live Activities | A configured plugin/Helper publishes machine-level readings, notification registrations and Activity updates. | Rex-only records have no Usage collector or background registration. | Check the correct unavailable state and the preceding registration/collection boundary. A Host with multiple backend records must not double-count its usage. Per-device notification banners do not supply APNs, ActivityKit tokens or widget readings. [Collector requirements](rex-host-services-parity.md) |

## Running the project checks

Use a disposable Unix SSH account accessible on loopback. On a Mac the
repository's isolated Herdr backend supplies a temporary HOME, SSH listener,
host key and the optional Herdr TUI reference. Use a dedicated Linux
container with no personal home mounted for the Linux runs. Start Rex
separately with that account's private socket, state and data directories.
Point regular shell startup and the SSH login at the same fixture PATH.

For RexProjectLiveTests, make a Git repository with a committed sample.txt,
modify it and add an untracked file named `new 文件.txt`. Install a global
Codex skill named `heeler-lab-daily` whose document contains `Global Codex
fixture body.`. Start a loopback HTTP listener returning exactly
`heeler-lab-preview-ok` from `/heeler-lab-preview`. Install ss or lsof on that
Host. A standalone foreground executable named claude writes one JSON receipt
per PID next to the supplied recorder path, containing pid, cwd, argv
(including argv[0]) and the selected test environment, and remains alive.
Only the synthetic recorder is used for argv delivery. Use the real
harness-specific suites for Chat.

The mode-0600 RexProjectLiveTests JSON takes port, user, the lab SSH seed
and pinned fingerprint, rexSocket, rexSession, rexBlock, project, recorder,
optional labBin and previewPort. The session and block identify the untouched
desktop shell. Set HEELER_REX_PROJECT_LAB to this file in the test
Simulator. The real SSH suite has its own fixture for a reachable socket,
a missing socket, and a listener that denies forwarding. Suites creating
temporary terminal blocks need an exclusive Rex socket. The inventory
read test instead needs an already populated server. Restore each simulator's
environment and stop only the listeners and processes created for that run.

```sh
make test-app TEST_SELECTOR=HeelerTests/RexConsoleTests
make test-app TEST_SELECTOR=HeelerTests/RexChatTypingTests
make test-app SCHEME=HeelerLiveTests TEST_SELECTOR=HeelerLiveTests/RexProjectLiveTests
make test-app SCHEME=HeelerLiveTests TEST_SELECTOR=HeelerLiveTests/RexChatTypingLiveTests
make test-app SCHEME=HeelerLiveTests TEST_SELECTOR=HeelerLiveTests/RexSSHLiveTests
```

Set SIM_DESTINATION to the explicit Simulator UDID on each invocation.
The accepted count comes from xcresulttool. A protocol probe, a fake,
a production Store on real SSH, a UI action and a physical delivery answer
different questions. [Testing](testing.md) · [Simulator setup](simulator-ui.md)
· [Linux fixture](rex-linux-lab.md) · [GUI observations](rex-simulator-acceptance.md)
