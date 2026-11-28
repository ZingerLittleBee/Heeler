# Rex daily workflows on iPhone and iPad

The application under review is `5c655f380d6cf63629f69d7436666ddba80f29c9` on `feat/rex-daily-workflows`. Herdr created the clean checkout from the fetched `origin/main` at `10148154331e5496afaef9b5b450d514fd1d7d8e`. The November 27–28, 2026 acceptance run used Heeler 0.1.18 (43), Herdr TUI 0.9.5 (protocol 22), and Rex 0.1.0-preview.25 (`b070aae645f5`). The Rex server advertised revision 24. Both regular Hosts selected 19. A separately constrained client negotiated 12. macOS 27.0.1 (26A434) and Debian 12.15 (7.2.12-orbstack) were both arm64. Xcode 27.2 (27B52) built the iOS/iPadOS 27.0 (24A434) Simulator product. The branch also contains test-driver and documentation commits after the verified application revision.

The [scenario-by-platform matrix](rex-daily-acceptance.md) covers ten harnesses and names the scope of each pass. The [source and gap map](rex-daily-workflows.md) traces the screen, store, projection, transport, and independent observation. Native Windows has no acceptance Host in this run.

## Delivered to a Rex-only Host

| Normal entry | Change and observed behavior |
| --- | --- |
| Hosts → select the Rex Server | See the Host OS, negotiated protocol and available Chat programs. Pull to refresh Terminals to re-read the running server. The missing-socket and refused-forwarding paths also ran over SSH. |
| Terminals → + or New Terminal Here · Agents → + | Name the new Tab, choose a directory, launch preset and literal arguments, or start in a new Git worktree. The selected Workspace and the focused side of a split determine the launch context. Workspace and Agent management names persist on the Rex server. An iPhone changed a real Pi conversation title with the harness command in the selected Terminal. Its separately assigned management name and the neighbor's title were preserved. |
| Agents → select an Agent → Chat | Grok Build gained native Chat on both Hosts and guarded Stop. OpenCode gained explicit, read-only history selection. Amp gained read-only access to its signed foreground thread through its optional plugin on both Hosts. Linux Antigravity gained native plain text after the first Terminal message has acquired an attributable lock. Multiple plausible writers leave the user with a history picker or Terminal. |
| Chat → Composer, permission card or Stop | The retained draft, staged files, displayed prompt and turn are checked against the selected server, block, foreground and official session. On uncertain acknowledgement the mobile retains the pending content. Claude Code and Codex each answered at most one request under repeated taps and a dropped reply on both Hosts. A separate Pi run on each recovered text and two staged items and inspected the peer's transcript. |
| Chat → Background Work | Factory Droid shows separately identifiable shell commands nested inside Script calls. Both Hosts showed the two confirmed running processes, then their separate outputs and exits 0 and 17 after reopening. In Devin, the phone launched independent jobs through the Composer and recovered their results and a child report after the parent had already replied. |
| Agent → Changes · keyboard → Skills · Settings → Notifications | POSIX Rex reuses the existing Git patch and Skills readers. On iPad, inserting a skill left it in the draft and preserved both official transcripts. Rex has a per-Host opt-in for foreground banners. On Debian Rex, repeated Blocked events produced one banner. Tapping separate Blocked and Done events opened the same observed Pi. Turning the switch off produced zero banners. |

## Existing capabilities checked again

The same-directory Rex and Herdr TUI pairs for Claude Code, Codex, Pi, Oh My Pi and Grok each sent and read the target reply on both Host systems. Ordinary signed Factory Droid and Devin exchanges also passed on both. The new tests distinguish those passes from approvals, directory trust, attachment handling, background work and per-task cancellation. The corresponding rows in the matrix are independent.

The seven raw transport scenarios on each Host included inventory, paint, typing and visible-terminal size ownership. The macOS client reached the native socket directly. The Debian raw client used an OpenSSH Unix-socket forward. Separate Heeler Simulator cases used libssh2 to connect to both Hosts, including dedicated Rex-only accounts. They recovered after an SSH cut and checked both a restored server and a replacement at the same address. The shell takeover experiment kept the desktop's unsubmitted line and the mobile draft.

Files, read-only Changes, Skills, Hand Off, port forwarding and GitHub use Host services over SSH. The handoff left both Agent histories unchanged. Installed `gh` clients listed items, wrote one issue comment, approved a review and merged a refreshed pull request once against an isolated, authenticated loopback service. The stale merge head produced no mutation. These receipts describe the client and private service used in the run. [Host and protocol observations](rex-host-services-parity.md) · [Independent witnesses](evidence/rex-final/scenario-evidence.json)

## Remaining differences

- Revision 19 cannot condition a destructive operation on the foreground or preserve desktop focus across all moves. The server ignored an experimental expected-foreground field on close. Moving a block could activate another window. Cross-session transfer needs revision 22 and undo needs 20. Heeler leaves native Close, Move and split rearrangement gated. Use the selected Terminal to exit its shell or Agent. A clean worktree can be removed through Git from a verified neighboring terminal. An empty Rex session may remain. [Probe results and requested upstream guarantees](rex-object-operations.md)
- The current app revalidates before it writes to Rex. Atomic exclusion of a desktop key between the final read and the server write requires a conditional input operation in Rex. The focused suite verified that Unknown status suppresses native Stop and Blocked Cards. On Linux the real Antigravity permission fallback used a Known Blocked foreground. A real Unknown-status Terminal action is separately marked NOT-RUN. The signed Droid supplemental tool-approval workflow did not complete on this candidate and AskUser did not get an independent positive result. Droid's separate hook and ordinary message/Stop tests passed. Older harness-specific passes remain dated. [Current matrix](rex-daily-acceptance.md) · [Earlier Droid matrix](droid-chat-validation.md)
- Amp sends through Terminal even when Chat has a verified read-only thread. OpenCode uses Terminal for input. Antigravity uses Terminal for permissions, attachments and its first unbound prompt. macOS Antigravity was waiting at the account’s terms and optional sharing choice. No decision was made on behalf of the account. Individual background-job Stop requires independent task identity. The two Factory Script tasks were verified for reading and completion.
- The device-local notification switch defaults off. Background APNs, a lock-screen Live Activity and Rex-only Usage/widgets need a persistent Host publisher and registration. A private Herdr relay has separate historical evidence. The paired iPhone 17 Pro Max was disconnected and the iPad Air (5th generation) had no developer services. Physical delivery, tapping a remote push, widgets and Lock Screen presentation are NOT-RUN. [Device availability and banner transitions](evidence/rex-final/scenario-evidence.json)
- Most harness-specific initial trust, plan and question permutations were not replayed. Long approval labels, rotation while holding a visible terminal and native Windows remain NOT-RUN where indicated. Read-only history, opening a permission in the right Terminal and actually answering it have different evidence.

## Installation and preferences

Droid’s opt-in hook is managed from the target Agent’s Chat. It merges its own entries into the SSH account’s `~/.factory/settings.json`. With an existing unrelated SessionStart handler, repeating installation created no duplicate and removal restored the original file bytes on both systems. Malformed settings refused the write. Pi and Oh My Pi use the Heeler session extension installed from Chat to publish the foreground conversation. Amp places `heeler-chat.js` under the foreground user’s `$XDG_CONFIG_HOME/amp/plugins` or `~/.config/amp/plugins`. Only a known previously shipped copy can be upgraded. Disabling or unloading it removes the active read binding and leaves Terminal available. The Rex foreground banner switch belongs to the individual Host on the phone. The existing Herdr plugin and Host Helper continue to own their registration and Usage services. [Chat installation details](../guides/chat.md) · [Host integrations](rex-host-services-parity.md)

## Test results

All final groups were run one at a time in a foreground terminal, using the pinned Simulator app and a named Simulator UDID. The ledger contains **160** completed `.xcresult` bundles, **333** method executions, **301** passes, **32** failures and **0** skips. Five incomplete attempts are separately listed. Repeated methods count each time they ran. A successful UI observer method needs its matching application/Host receipt before a user action gets a pass. Of the executed methods, 136 were focused Simulator unit cases. Seven repository-tool checks and 31 Node tests also passed, counted separately from XCTest. [Method, device and bundle index](evidence/rex-final/results.json)

The 32 failed method executions include nine early private GitHub fixture failures, four SSH cases on an unreachable fixture endpoint, one Grok touch attempt, two Devin runs and sixteen Droid runs. Later successes on the original app are recorded next to the failed attempts. Two dedicated listeners exercised accepted and refused forwarding. A fresh signed macOS Devin targeted the correct conversation. The corrected loopback GitHub fixture returned the response fields requested by its actual clients. The iPhone Grok action passed on an isolated A/B server for each OS. Droid's malformed settings were deliberately left untouched, then the positive restoration case used valid JSON with an unrelated handler. The supplemental Droid controls remain open.

The app's debug dylib SHA-256 was `58d2518e856a141d5838be745b68a7990a5a7abb376af811a5f738c3a81a5ee5`. GitHub fixture changes start at `da25ececf`. The final Droid test sources are `3193521b2` and `65bc7639f`. Each new Droid driver was installed inside the original candidate bundle. All **931 other application files** were compared byte-for-byte for each replacement. This includes the application binary, extensions, resources and other test bundles. The two driver hashes and the original product hash are in the [driver receipts](evidence/rex-final/scenario-evidence.json).

The following result bundles are in `build/heeler-lab-evidence/`.

| Area | Result bundle or pair |
| --- | --- |
| Unit checks, including FakeRexServer, stale input and ownership | `final-5c655f380-units.xcresult` |
| Actual Host services, missing socket and SSH refusal | `final-5c655f380-mixed-{mac,linux}.xcresult` and `final-5c655f380-mac-ssh-alias-listeners.xcresult` |
| Raw Rex typing and visible terminal size | `final-5c655f380-raw-{mac,linux}-{typing,size}.xcresult` |
| Recovered server and replacement server | `final-5c655f380-recovery-{mac,linux}.xcresult` |
| Signed Droid ordinary messages and scoped foreground Stop | `droid-5c655f380-65bc7639f-{mac,linux}-message.xcresult` |
| Droid hook idempotence and settings restoration | `droid-5c655f380-65bc7639f-mac-validjson.xcresult` and `droid-5c655f380-65bc7639f-linux-prefs.xcresult` |
| Signed Devin jobs and late child reports | `chat/5c655f380-unified-mac-devin-phone-fresh.xcresult` and `unified-5c655f380-u5c655-phone.xcresult` |

For replay, prepare a new disposable foreground and a new marker as described in the [testing guide](testing.md). The regular entry points were `make test-app TEST_SELECTOR='HeelerTests/RexConsoleTests'` and `make test-app SCHEME=HeelerLiveTests TEST_SELECTOR='HeelerLiveTests/RexSSHLiveTests'`. Supply `SIM_DESTINATION='platform=iOS Simulator,id=<UDID>'` and `TEST_XCTESTRUN=<pinned build manifest>`. The [exact selectors including live Chat, staging and Herdr references](evidence/rex-final/results.json) retain the method names and actual devices for this run.

Two disposable loopback SSH credentials were displayed in an earlier diagnostic. Both were replaced. The previous identities were refused on all nine affected QA listeners, and the new identities were accepted on the intended listeners. No personal SSH key was involved. [macOS rotation](evidence/rex-candidate/mac-key-rotation.json) · [Debian rotation](evidence/rex-candidate/linux-key-rotation.json)

## Fixture cleanup

Both independently identified Debian containers and their private accounts, 33 macOS temporary directories, and 11 test Simulators were removed. The signed Amp exporter confirmed that the seven individually registered Debian test threads no longer existed. Nine implementation worktrees and eight helper Herdr Workspaces were retired. The review branch and its Herdr Workspace remain available, alongside the original result bundles. [Cleanup receipts](evidence/rex-final/cleanup.json)

## Screenshots

The ordinary iPhone 17e used UDID `38FC9720-0863-416A-89F3-45CED5F13CE6`. The iPad mini used `BC0A885C-C04E-41D8-879D-3FAC08209085`. Its observed app window occupied 561.5 × 744 points on a 1133 × 744 point display. Each screenshot has an original path, digest and matching running-app receipt. [Evidence manifest](evidence/rex-final/scenario-evidence.json)

| Screen | Captures |
| --- | --- |
| iPhone, Rex-only Host and selected shell | [Capabilities](evidence/rex-final/iphone-linux-capabilities.png) · [Shell marker and directory](evidence/rex-final/iphone-verified-shell.png) |
| iPhone, native management name and harness title | [Pi conversation title](evidence/rex-final/iphone-pi-title.png) |
| iPhone, scoped foreground control | [Native Grok Stop](evidence/rex-final/iphone-grok-stop.png) |
| iPad in an actual half-width window | [Worktree and preset form](evidence/rex-final/ipad-worktree.png) · [Unsent skill draft](evidence/rex-final/ipad-skill-draft.png) |
| iPad, Debian Rex notifications | [Blocked recipient](evidence/rex-final/ipad-blocked-recipient.png) · [Done recipient](evidence/rex-final/ipad-done-recipient.png) |
