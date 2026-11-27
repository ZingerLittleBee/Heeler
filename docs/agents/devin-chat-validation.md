# Devin CLI Chat acceptance

The [Chat guide](../guides/chat.md#devin-cli) explains how to open a running local Devin. Heeler identifies the session with the lock held open by the foreground client's ACP writer. The writer's PID, process start, terminal identity and backend instance bind an input request. Session slugs belong to the account store that owns the lock. A shared daemon or a cloud connection has no verified local writer for this path.

## Environment

| Component | macOS Host | Linux Host |
| --- | --- | --- |
| Host | macOS 27.0.1 (26A434), arm64 | Debian 12.15 arm64, Linux 7.2.12, disposable local container |
| Devin CLI | 3000.15.14, cfa79668e1a5 | Same build |
| Herdr TUI / herdr-core | 0.9.5 / 0.1.22 | 0.9.5 / 0.1.22 |
| tmux | 3.7b | 3.3a |
| Rex | 0.1.0-preview.25, b070aae645f5, server API 24 | Same build |
| Simulator | 11-inch iPad Pro (M4), iPadOS 27.0 | iPhone 17 Pro, iOS 27.0 |
| Xcode | 27.2 (27B52) | The iPhone simulator used the same Xcode on the Mac |

The runs on November 27, 2026 exercised the implementation in `878a25867e5d4f974e5d2ff01e1b7119778123a3`. The live suite and inspected candidate were `3fbbae2f2b8eff885900bdf52264bb3d592bc04a`, built on `354497fb6da76ecb93bb02e6cab4c86250b6c384`.

Both fixtures connected over loopback SSH with pinned host keys. Each had a named Herdr TUI server, a separate herdr-core instance, a private tmux socket and a private Rex server. The live tests independently checked the initial slug against the writer's open lock before they used the production Chat store, Composer and backend typing path. Both systems used the owner's existing login. The Linux credential was confined to the temporary container. The private SSH fixture and authentication data are outside the repository.

## Backend, system and scenario

Each cell identifies the user control and the verification result. **N** means a native Chat action, **R** means Chat displays the information, and **T** means to use that terminal. **PASS** requires an observation on the indicated backend and system. **NOT-RUN** marks a path without an end-to-end run there. **N/A** marks an unavailable backend. The regular Rex cases and its Unknown cases are distinguished below. “Both” applies independently to the macOS and Linux Hosts.

| System | Scenario | Herdr TUI | herdr-core | tmux | Rex |
| --- | --- | --- | --- | --- | --- |
| macOS | Open the foreground session and send multiline text with Chinese, a blank line and indentation | N PASS | N PASS | N PASS | N PASS |
| Linux | Open the foreground session and send the same text | N PASS | N PASS | N PASS | N PASS |
| macOS | Trust a fresh directory and receive the first reply | N PASS | N PASS | N PASS | T PASS, then N PASS |
| Linux | Trust a fresh directory and receive the first reply | N PASS | N PASS | N PASS | T PASS, then N PASS |
| macOS | Decline trust, exit, then tap the stale card | N PASS | N NOT-RUN | N NOT-RUN | T NOT-RUN |
| Linux | Decline trust, exit, then tap the stale card | N PASS | N NOT-RUN | N NOT-RUN | T NOT-RUN |
| macOS | Allow write A, decline write B on desktop, replay stale cards, verify disk | N PASS | N PASS | N PASS | N PASS |
| Linux | Allow write A, decline write B on desktop, replay stale cards, verify disk | N PASS | N PASS | N PASS | N PASS |
| macOS | Review a wrapped command, move its desktop scope to Session, choose Once in Chat, read its output | N PASS | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| Linux | Review a wrapped command, move its desktop scope to Session, choose Once in Chat, read its output | N PASS | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| macOS | Answer two questions, including a custom response | N PASS | N PASS | N PASS | N PASS |
| Linux | Answer two questions, including a custom response | N PASS | N PASS | N PASS | N PASS |
| macOS | Review a plan, decline, send feedback, preserve the ordinary draft | N PASS | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| Linux | Review a plan, decline, send feedback, preserve the ordinary draft | N PASS | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| macOS | Stop the displayed turn and use its old Stop during another turn | N PASS | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| Linux | Stop the displayed turn and use its old Stop during another turn | N PASS | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| macOS | Reopen two named shell outputs, a stopped shell and one subagent report | R PASS | R NOT-RUN | R NOT-RUN | R NOT-RUN |
| Linux | Reopen two named shell outputs, a stopped shell and one subagent report | R PASS | R NOT-RUN | R NOT-RUN | R NOT-RUN |
| macOS | Stop a selected background shell in the terminal while a sibling finishes normally | T PASS | T NOT-RUN | T NOT-RUN | T NOT-RUN |
| Linux | Stop a selected background shell in the terminal and read each terminal result | T PASS | T NOT-RUN | T NOT-RUN | T NOT-RUN |
| macOS | Leave an unsent draft through `/clear`, `/resume` and an SSH disconnect with a desktop switch | N PASS | N PASS | N PASS | N PASS |
| Linux | Leave an unsent draft through `/clear`, `/resume` and an SSH disconnect with a desktop switch | N PASS | N PASS | N PASS | N PASS |
| macOS | Use `/fork` in the terminal, remain in the original, then explicitly resume the copy | T PASS | T NOT-RUN | T NOT-RUN | T NOT-RUN |
| Linux | Use `/fork` in the terminal, remain in the original, then explicitly resume the copy | T PASS | T NOT-RUN | T NOT-RUN | T NOT-RUN |
| Both | Grant persistent permissions or approve a plan that switches to Accept edits or Bypass | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| Both | Incomplete or unsupported MCP requests, sandbox prompts, model and skill pickers, steering and Bash mode | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN |
| Both | Staged files and images with spaces or Unicode in their names, and upload recovery after a send failure | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN |
| Both | Replace the backend server, reuse a PID or pane, nest tmux or change the Rex block's foreground program during Send | R NOT-RUN | R NOT-RUN | R NOT-RUN | R NOT-RUN |
| Both | Approvals or Stop on a Rex block reporting Unknown | N/A | N/A | N/A | T NOT-RUN |
| Native Windows | All Devin scenarios, platform skipped | T NOT-RUN | T NOT-RUN | N/A | T NOT-RUN |

Rex's fresh trust fixtures returned an empty `program_status.records` on both Hosts. The user confirmed the directory in the terminal and subsequently sent from native Chat. The separate Rex write and question cases ran with an owned Devin program status. The reported-status requirement also applies to Rex Stop. The core and tmux trust cases used native controls before the writer owned a session lock. Session and project-wide command permissions were inspected on screen. The command acceptance runs executed only the Once option.

On each Host, an ordinary terminal launched `devin` with no arguments. Once startup settled, its ACP child held one session lock. The terminal's `/fork` left the original lock open and printed the command for opening the copy. After explicit resume the new writer held the copy's lock. Both histories retained the shared initial message ID. The next private marker appeared only in the original and the last marker only in the copy.

The Linux subagent's final report arrived 18 seconds after the parent response. Its attempt to run a command requiring approval in the background was denied. It reported that outcome under its own child ID, alongside the two successful shell outputs.

## What the CLI showed

- **Identity and startup.** A local interactive client has a direct child with argv containing both `acp` and `--process-model=in-process`. Its open `devin/cli/session_locks/<slug>.lock` contains its PID and a newline. On Linux with `--process-model=daemon`, the separate daemon owned the lock. Chat provides a terminal entry for that configuration. A client can display both trust choices before it owns any lock. During a desktop `/resume` the ACP writer can change while herdr's status and reported session stay the same. Visible Chat periodically verifies the foreground again.
- **Input and approval.** The idle placeholder has a distinguishable color: `38;2;124;124;124` under `theme_mode` dark and `38;2;107;107;107` under light (3000.15.14, 2026-11-27, `devin-light-idle`), while a draft is in the default color, so Heeler takes any color or dim as the placeholder. Unstyled text identical to the placeholder, desktop drafts, menus, the working-turn steering field, and the Bash field hold ordinary Send. Each actionable card is bound to both the live screen and a single still-pending tool call. Scoped command approval offered Once, Session, Project and Always. The probe inspected all four scopes. Only one-time permissions were exercised. A write card exposed the path, diff, Allow, Accept edits mode, Bypass mode and Deny. Wrapped commands must account for the full submitted command. Unsupported parameters, incomplete proposals and unsupported tools lead to the terminal.
- **Questions and plans.** The active page of a multi-question call has its own numbered choices and Other field. Devin adds a checkmark to the tab while the user types. The card matches a unique question and its option descriptions. A plan proposal has the complete text and three choices, including the mode change attached to each Yes. Declining leads back to the Plan input field. The feedback composer has its own draft.
- **Background work.** The main turn, an acknowledged shell launch, a shell's exit, and the child agent's report have independent IDs. A shell's exit code or an explicit user-kill result supplies its final state. An unanswered output request retains the last known state. The initial query also retrieves bounded earlier task records from the same active chain, so reopening can restore work outside the first timeline page. The read bounds are 128 earlier task calls and 128 KiB of earlier task events. The final public child report can arrive through a typed relay or a completed subagent head.
- **Stopping one background task.** On macOS the terminal's Shells tab listed the two test shell IDs and their commands. Pressing `x` immediately stopped the highlighted shell and moved selection to the surviving shell. A subsequent `get_output` for the selected ID returned the explicit user-kill result. Its sibling returned exit code 0. The child detail showed a title and tool count without an agent ID. Chat keeps task control in the terminal because the list can change the target of that single key. A turn-level Stop has its own foreground and turn checks.
- **Storage.** The bounded Python reader uses SQLite in read-only mode and follows the selected session's parent chain. Tool results attach by call ID. It filters injected user messages and thinking blocks. Paging, adjacent writes, branches, truncated results and a late child report have separate fixtures. Heeler uses no Devin plugin and changes no settings to support Chat.

The simulator captures show the native [iPad trust card](evidence/devin-chat/ipad-trust.png), [iPhone command approval](evidence/devin-chat/iphone-command.png), [iPad question with write-in](evidence/devin-chat/ipad-question.png) and [iPhone plan review](evidence/devin-chat/iphone-plan.png).

The [captured terminal screens](../../Tests/HeelerTests/ChatFixtures/screens/devin), [focused app cases](../../Tests/HeelerTests/DevinChatTests.swift), [SQLite reader tests](../../scripts/test-devin-session.py) and [real backend suite](../../Tests/HeelerLiveTests/DevinChatLiveTests.swift) document the inputs used for these observations. Cognition describes session workflows and hook semantics in its [CLI documentation](https://docs.devin.ai/cli) and [hook lifecycle reference](https://docs.devin.ai/cli/extensibility/hooks/lifecycle-hooks).

## Reproducing the runs

Use the Heeler scheme for app tests and HeelerLiveTests for live SSH. Give each scheme its own derived data directory. See the [testing guide](testing.md) for test selection and the result-bundle count check.

- `DevinChatTests` exercises lock ownership, captured screens, exact tool requests and draft recovery. `scripts/test-devin-session.py` exercises the bundled SQLite query in a temporary database.
- `DevinChatLiveTests` reads `HEELER_DEVIN_LAB_MAC` and `HEELER_DEVIN_LAB_LINUX` inside the simulator. Each is a private JSON fixture with the SSH port, username, seed, host fingerprint, server endpoints, pane IDs, workspace and expected slugs. `HEELER_DEVIN_BEHAVIOR_PLATFORM` chooses the Host. Its two fresh TUI startup panes test acceptance and exit. `HEELER_DEVIN_STARTUP_LABS` points at the three equivalent backend fixtures.
- `HEELER_DEVIN_STOP_PLATFORM` enables a two-turn Stop test. `HEELER_DEVIN_PLAN_LAB` identifies a separate client whose home and plan files are in the disposable directory. `HEELER_DEVIN_BACKGROUND_LAB` identifies a read-only reopen fixture with a checked parent session, two shell outputs, an optionally stopped shell and a known child report. `HEELER_DEVIN_SCREENSHOTS` saves the actual native card in the simulator window. These screenshots exercise the card component over a live backend. The optional `HEELER_DEVIN_COMMAND_LABS` folder supplies the two isolated terminals for the long command and scope test.

### Results

The [portable run record](evidence/devin-chat-3000.15.14.json) contains the per-backend results, message and tool-call IDs, file hashes, session transitions and background job outcomes. Each of the eight backend and OS combinations recorded one user message and one reply for its send marker. Each also recorded the correct contents in A, a declined call and no file for B, and zero copies of the parked draft after the online and offline switches. The post-exit observer received zero input bytes during the 15 seconds following declined trust on each Herdr TUI Host.

| Command or suite | Executed | Result |
| --- | --- | --- |
| `make test-app TEST_SELECTOR='HeelerTests/DevinChatTests'` with `-only-testing:HeelerTests/DroidChatTests` | 9 Devin and 21 Droid tests | 30 passed |
| `make test-app SCHEME=HeelerLiveTests TEST_SELECTOR='HeelerLiveTests/DevinChatLiveTests'`, iPad | 7 enabled methods, 15 cases | 15 passed |
| Same live suite, iPhone | 8 enabled methods, 17 cases | 17 passed, including the scoped command on each Host |
| `python3 scripts/test-devin-session.py` | 4 SQLite reader tests | 4 passed |
| `make test-tools` | 37 tooling checks | 37 passed |
| Shared Chat and backend suites at the production revision | 363 tests in 13 suites | 362 passed, 1 failed |

The iPhone executed both Host arguments of the scoped-command method. The iPad skipped that optional method. Each parameterized method counts once in the Xcode summary. The case counts above expand its arguments. The focused app and live selectors were verified against their result bundles. The shared failure was `HerdrCoreChatTests/statusTurnAndForegroundEventsEachCheckAgain()`. A fresh checkout of the base reproduced its event-count failure. In early tooling runs, the watchdog test detected concurrent `sleep 10` processes and a process-reader fixture matched the substring `999` in a real PID. The full tooling repeat used a settled test environment.

The simulator runs exercised the actual native cards and real Host connections. The disconnect test suspended the SSH projection and the Chat store while an independent SSH connection changed Devin's session. The process stayed alive on the Host throughout. OS eviction, native Windows, persistent permission grants, attachment recovery, server replacement and foreground program replacement remain outside these live runs.
