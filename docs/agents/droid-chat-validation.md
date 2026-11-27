# Factory Droid Chat acceptance

The implementation candidate is `e433870600d26395bf7d1d4842a9416957bdab06`. The full TUI suites, macOS backend suite and focused suite used this candidate. A subsequent test-only change, `686a2c07f0a82029439f89f06e8147a304f255cf`, used the app’s existing Done-to-idle mapping for the targeted Stop reruns. The final Linux backend run and supplemental checks also used that test revision. The production Swift sources, host scripts, project and assets are identical between those commits. The work started at `f858cee5b30890352d3cea267ef228147992e587`. The pre-existing macOS backend changes are preserved in `59d44b133a77459f8cf45ee7fa84fee19fc65881`. Native Windows was skipped as requested.

**N** means the operation uses a native Chat control, **R** means the result or identity can be inspected, and **T** means the user acts in the indicated terminal. Each cell has its own evidence status. A PASS for T records the terminal workflow. A PASS for R records a read or identity check. A cell with two entries identifies the device path and the separately exercised terminal path. NOT-RUN covers the specific operation in that cell, including when only a shared parser or transport test ran. N/A identifies an inapplicable platform or operation. The checkout’s local evidence bundle is `build/droid-acceptance/`. The controls apply to a correctly bound, supported foreground Droid. A terminal PASS can coexist with an implemented native control that did not receive a device run on that backend.

The [portable verification record](evidence/droid-chat-1.21.1.json) includes evidence extracted from the four flow transcripts, the measured test counts, and backend ownership observations. The local index at `build/droid-acceptance/report.md` links the test receipts, Xcode results and native card images.

## Hosts and clients

| Component | macOS | Linux |
| --- | --- | --- |
| Host | macOS 27.0.1, Apple silicon | Debian 13.7 arm64, local temporary container, Linux 7.2.12 Orbstack |
| Droid | Factory 1.21.1 | Factory 1.21.1 |
| Herdr TUI / herdr-core | 0.9.5 / 0.1.22 | 0.9.5 / 0.1.22 |
| tmux | 3.7b | 3.5a |
| Rex | 0.1.0-preview.25, server API 24, negotiated API 19 | Same release and protocol range |
| App | iOS/iPadOS 27 simulator on Xcode 27.2 (27B52) | Same app, connecting over SSH |

The behavior suites used local loopback SSH with pinned host keys, distinct terminal addresses, disposable checkouts and the account’s existing Factory subscription. Direct-tool scenarios used Gemini 4 Hydrogen. The separate Script-wrapped cases were observed with Opus 5.5. Existing Factory credentials were used locally on the Mac and temporarily inside the local Linux container.


## Four user flows

The rows below use the two Herdr TUI device runs. Core, tmux and Rex have separate live receipts in the platform tables. A separate terminal input path supplied the desktop responses. The background test suspended and resumed the Chat store. The reconnect test also suspended and resumed the SSH projection. OS process eviction was not exercised.

| Flow | macOS Host, iPad | Linux Host, iPhone |
| --- | --- | --- |
| First startup trust and decline | Reply `DROID_TRUST_6D47EA65` in `7bd01d58-b979-414d-bac0-263380dcf358`. The raw shell observer remained `ready`. | Reply `DROID_TRUST_BCAB251B` in `6e2f3d2a-2251-4cb8-96f9-cd9f28b4a44f`. The raw shell observer remained `ready`. |
| Consecutive file approvals | `call_decd9028e7392c04_0` and `call_9c10b805a72b3490_0`. The first file contained `ALPHA-DROID` and one newline. The second file was absent. | `call_b802891078ad72ba_0` and `call_79a18f5b3bb6c337_0`. The first file contained `ALPHA-DROID` and one newline. The second file was absent. |
| Two background commands and one asynchronous child | `RED_1E9C45` (PID 79295, signal SIGTERM), `BLUE_1E9C45` (PID 79315, code 0). The worker reported `CHILD_1E9C45` once under `d422be9f-c23c-4c53-a502-5e828660caea`. | `RED_EE1A6D` (PID 174761, signal SIGTERM), `BLUE_EE1A6D` (PID 174765, code 0). The worker reported `CHILD_EE1A6D` once under `2d2eaff9-6ad7-409e-a133-c823b2dc26c0`. |
| Draft, fork and reconnect | The shared directory contained 3 header-verified transcripts with 0 copies of the unsent draft. The device recovered the draft on returning to A. | The shared directory contained 3 header-verified transcripts with 0 copies of the unsent draft. The device recovered the draft on returning to A. |

## macOS

| Scenario | Herdr TUI | herdr-core | tmux | Rex |
| --- | --- | --- | --- | --- |
| Open the running conversation, verify its UUID, send a unique marker, read one reply | N / PASS | N / PASS | N / PASS | N / PASS |
| First trust, approve the whole path and bind the new UUID | N / PASS | N / PASS | N / PASS | T / PASS |
| Open a known trusted directory, locate an existing running conversation | N / PASS | N / PASS | N / PASS | N / NOT-RUN |
| Distinguish startup, unreadable screen and missing or disabled hook | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Decline startup trust, press the old card and inspect the receiving shell for bytes | N / PASS | N / NOT-RUN | N / NOT-RUN | T / NOT-RUN |
| Start Droid inside a registered Git worktree and approve it on the device | N / PASS | N / NOT-RUN | N / NOT-RUN | T / NOT-RUN |
| Cancel a change to an untrusted sibling, accept it and continue in that directory | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Allow creation of A, desktop denies B, replay both cards, verify file contents | N / PASS | N / PASS | N / PASS | N / PASS |
| Review the complete long command, including its elided middle, then decline | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Approve a two-file git patch after checking its complete bytes, verify both files | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Approve a direct file edit after inspecting its removed and added text | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Inspect the exact scope of the offered always-allow choice | R / PASS | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Select the always-allow low-impact choice and observe session and account defaults | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Review a network command directed only at an isolated loopback server | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Read the reason from an enforced Factory policy block | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Answer an MCP request nested in Script with no matching inner call ID | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Approve an operation triggering a separate sandbox permission | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Choose an AskUser answer and receive it in the conversation | N / PASS | N / PASS | N / PASS | N / PASS |
| Edit a multi-question form, enter a custom answer, review and submit | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Cancel an AskUser form on the device | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Review a Spec, request a revision, preserve the ordinary draft and approve autonomy | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Hand a Spec to a new session and prove the foreground UUID changed | N / PASS | N / NOT-RUN | N / NOT-RUN, T / PASS | N / NOT-RUN |
| Send multiline Chinese and stage an image and a file with spaces in the path | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Desktop has a draft, attachment upload completes, mobile send is held and recovered | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Stop a verified active turn and observe its interrupted outcome | N / PASS | N / PASS | N / PASS | N / PASS |
| Send a steering message during generation and read its reply in the same conversation | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Queue two messages and clear the entire queue before either reaches a turn | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Independent Execute tasks, app suspension, task-specific output and targeted stop | N / PASS | N / PASS | N / PASS | N / PASS |
| Late asynchronous sub-Droid report attaches to its own task exactly once | N / PASS | N / PASS | N / PASS | N / PASS |
| Cancel only an identified sub-Droid from its details | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Read a background command’s nonzero exit and identify the separate parent reply | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN, T / PASS | R / NOT-RUN |
| Read a disconnected background task’s last reported state | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Task details clip the command, refuse Kill and retain the last recorded state | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Hold a message for A when the desktop switches sessions with /new | N / PASS | N / PASS | N / PASS | N / PASS |
| Two live Droids in one directory, fork stays in A, explicit resume follows the copy | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| SSH disconnect, switch while disconnected, recover A’s unsent draft | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Merge transcript pages, call results and hidden hook records by identity | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Desktop /clear switches UUID and /compress keeps it after confirmation | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Heeler New Agent uses process-only settings, hook binds a new UUID in the same directory | N/A / N/A | N / PASS | N / PASS | N/A / N/A |
| Explicit install, repeat, remove and preserve existing Factory settings | N/A / N/A | N / NOT-RUN | N / NOT-RUN | N / PASS |
| Disable Factory hooks, enable again and resume the same UUID in another process | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Supply a custom --settings argument and keep the user’s launch settings | N/A / N/A | N / NOT-RUN | N / NOT-RUN | N/A / N/A |
| Inspect model and reasoning, slash menu, skills, side chat, empty Mission Control and Bash mode | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Open a project-specific custom command in the slash menu | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Inspect an active Mission worker, milestones and waiting input | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Read a user-visible network failure and keep it out of the user’s messages | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Finish Factory login in the indicated terminal | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Read an unrecognized dialog and follow its terminal entry | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Handle a real account quota or rate limit | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Stop from A remains harmless after the same foreground Droid starts another turn | N / PASS | N / PASS | N / PASS | N / PASS |
| Server replacement or a recreated pane cannot receive input from an old Chat | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Restart a terminal or reuse a PID while a stale permission card is open | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Keep the desktop terminal size, owner and focus through Chat actions | N/A / N/A | N/A / N/A | R / PASS | R / PASS |
| Same-number panes on separate tmux sockets and a replacement on the first socket | N/A / N/A | N/A / N/A | R / PASS | N/A / N/A |
| Read a nested tmux client and its inner Droid displaying the same screen | N/A / N/A | N/A / N/A | R / PASS | N/A / N/A |
| Deliver a stale action after nesting tmux or replacing Droid on the same terminal | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |

## Linux

| Scenario | Herdr TUI | herdr-core | tmux | Rex |
| --- | --- | --- | --- | --- |
| Open the running conversation, verify its UUID, send a unique marker, read one reply | N / PASS | N / PASS | N / PASS | N / PASS |
| First trust, approve the whole path and bind the new UUID | N / PASS | N / PASS | N / PASS | T / PASS |
| Open a known trusted directory, locate an existing running conversation | N / PASS | N / PASS | N / PASS | N / NOT-RUN |
| Distinguish startup, unreadable screen and missing or disabled hook | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Decline startup trust, press the old card and inspect the receiving shell for bytes | N / PASS | N / NOT-RUN | N / NOT-RUN | T / NOT-RUN |
| Start Droid inside a registered Git worktree and approve it on the device | N / PASS | N / NOT-RUN | N / NOT-RUN | T / NOT-RUN |
| Cancel a change to an untrusted sibling, accept it and continue in that directory | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Allow creation of A, desktop denies B, replay both cards, verify file contents | N / PASS | N / PASS | N / PASS | N / PASS |
| Review the complete long command, including its elided middle, then decline | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Approve a two-file git patch after checking its complete bytes, verify both files | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Approve a direct file edit after inspecting its removed and added text | N / PASS | N / NOT-RUN | N / NOT-RUN, T / PASS | N / NOT-RUN |
| Inspect the exact scope of the offered always-allow choice | R / PASS | R / NOT-RUN | R / PASS | R / NOT-RUN |
| Select the always-allow low-impact choice and observe session and account defaults | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN, T / PASS | N / NOT-RUN |
| Review a network command directed only at an isolated loopback server | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN, T / PASS | N / NOT-RUN |
| Read the reason from an enforced Factory policy block | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN, T / PASS | R / NOT-RUN |
| Answer an MCP request nested in Script with no matching inner call ID | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Approve an operation triggering a separate sandbox permission | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Choose an AskUser answer and receive it in the conversation | N / PASS | N / PASS | N / PASS | N / PASS |
| Edit a multi-question form, enter a custom answer, review and submit | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Cancel an AskUser form on the device | N / PASS | N / NOT-RUN | N / NOT-RUN, T / PASS | N / NOT-RUN |
| Review a Spec, request a revision, preserve the ordinary draft and approve autonomy | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Hand a Spec to a new session and prove the foreground UUID changed | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Send multiline Chinese and stage an image and a file with spaces in the path | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Desktop has a draft, attachment upload completes, mobile send is held and recovered | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Stop a verified active turn and observe its interrupted outcome | N / PASS | N / PASS | N / PASS | N / PASS |
| Send a steering message during generation and read its reply in the same conversation | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Queue two messages and clear the entire queue before either reaches a turn | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Independent Execute tasks, app suspension, task-specific output and targeted stop | N / PASS | N / PASS | N / PASS | N / PASS |
| Late asynchronous sub-Droid report attaches to its own task exactly once | N / PASS | N / PASS | N / PASS | N / PASS |
| Cancel only an identified sub-Droid from its details | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Read a background command’s nonzero exit and identify the separate parent reply | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN, T / PASS | R / NOT-RUN |
| Read a disconnected background task’s last reported state | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Task details clip the command, refuse Kill and retain the last recorded state | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / PASS |
| Hold a message for A when the desktop switches sessions with /new | N / PASS | N / PASS | N / PASS | N / PASS |
| Two live Droids in one directory, fork stays in A, explicit resume follows the copy | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| SSH disconnect, switch while disconnected, recover A’s unsent draft | N / PASS | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Merge transcript pages, call results and hidden hook records by identity | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Desktop /clear switches UUID and /compress keeps it after confirmation | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Heeler New Agent uses process-only settings, hook binds a new UUID in the same directory | N/A / N/A | N / PASS | N / PASS | N/A / N/A |
| Explicit install, repeat, remove and preserve existing Factory settings | N/A / N/A | N / NOT-RUN | N / NOT-RUN | N / PASS |
| Disable Factory hooks, enable again and resume the same UUID in another process | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Supply a custom --settings argument and keep the user’s launch settings | N/A / N/A | N / NOT-RUN | N / NOT-RUN | N/A / N/A |
| Inspect model and reasoning, slash menu, skills, side chat, empty Mission Control and Bash mode | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Open a project-specific custom command in the slash menu | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Inspect an active Mission worker, milestones and waiting input | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Read a user-visible network failure and keep it out of the user’s messages | R / NOT-RUN | R / NOT-RUN | R / PASS | R / NOT-RUN |
| Finish Factory login in the indicated terminal | T / NOT-RUN | T / NOT-RUN | T / PASS | T / NOT-RUN |
| Read an unrecognized dialog and follow its terminal entry | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN | R / NOT-RUN |
| Handle a real account quota or rate limit | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN | T / NOT-RUN |
| Stop from A remains harmless after the same foreground Droid starts another turn | N / PASS | N / PASS | N / PASS | N / PASS |
| Server replacement or a recreated pane cannot receive input from an old Chat | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Restart a terminal or reuse a PID while a stale permission card is open | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |
| Keep the desktop terminal size, owner and focus through Chat actions | N/A / N/A | N/A / N/A | R / PASS | R / PASS |
| Same-number panes on separate tmux sockets and a replacement on the first socket | N/A / N/A | N/A / N/A | R / PASS | N/A / N/A |
| Read a nested tmux client and its inner Droid displaying the same screen | N/A / N/A | N/A / N/A | R / PASS | N/A / N/A |
| Deliver a stale action after nesting tmux or replacing Droid on the same terminal | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN | N / NOT-RUN |

## Native Windows

| Scenario | Herdr TUI | herdr-core | tmux | Rex |
| --- | --- | --- | --- | --- |
| All Droid Chat scenarios above | T / NOT-RUN | T / NOT-RUN | N/A / N/A | T / NOT-RUN |

Native Windows was skipped at the user’s request. The implementation enables no new Windows capability.

## Executed tests

| Selector or scope | Verification | Selected and executed | Evidence file |
| --- | --- | --- | --- |
| DroidChatTests | PASS | 14 of 14, 0 skipped | `focused-e43387060.txt` |
| Real Herdr TUI on iPad, macOS | FAIL | 15 executed, 2 methods failed | `mac-tui-ipad-e43387060.txt` |
| Real Herdr TUI on iPhone, Linux | FAIL | 15 executed, 1 methods failed | `linux-tui-e43387060.txt` |
| Real macOS core, tmux and Rex | PASS | 1 of 1, 0 skipped (3 backend cases in one parameterized test) | `mac-backends-e43387060.txt` |
| Real Linux core, tmux and Rex | PASS | 1 of 1, 0 skipped (3 backend cases in one parameterized test) | `linux-backends-final-686a2c07f.txt` |
| New-session Stop rerun on macOS / iPad | PASS | 1 of 1, 0 skipped | `stop-mac-686a2c07f.txt` |
| New-session Stop rerun on Linux / iPhone | PASS | 1 of 1, 0 skipped | `stop-linux-686a2c07f.txt` |
| Spec handoff rerun on macOS / iPad | PASS | 1 of 1, 0 skipped | `handoff-mac-686a2c07f.txt` |
| Shared transport, identity and Host capabilities (5 suites) | PASS | 80 of 80, 0 skipped | `transport-targeted-686a2c07f.txt` |
| Real Rex control link and size invariance, macOS | PASS | 1 of 1, 0 skipped | `rex-transport-686a2c07f.txt` |
| Focused tests on the test-only revision | PASS | 14 of 14, 0 skipped | `focused-proof-686a2c07f.txt` |
| Broader regressions including HerdrCoreChatTests | FAIL | 125 executed, 2 methods failed | `transport-complete-686a2c07f.txt` |
| Linux checked Send and Stop with another Rex terminal client owning the block | PASS | 1 of 1, 0 skipped (3 backend cases in one parameterized test) | `owner-linux-686a2c07f.txt` |
| macOS checked Send and Stop with another Rex terminal client owning the block | PASS | 1 of 1, 0 skipped (3 backend cases in one parameterized test) | `owner-mac-686a2c07f.txt` |
| Initial revision, two supplemental core regressions | FAIL | 2 executed, 2 methods failed | `regression-baseline-f858cee5b.txt` |

## Reading the evidence

- **Trust and input.** The native trust card is available on Herdr TUI, herdr-core and tmux with positive foreground process, path, prompt and focus evidence. It can exist before Factory creates its first UUID. A Rex block reporting Unknown directs the user to that block’s terminal. Once trust succeeds, the same Chat can bind the new header and send. The recordings also distinguish Factory login, incomplete startup, a failed screen read and a missing or disabled hook.
- **Approval identity.** The card requires the same terminal instance, process birth, UUID, open tool-call ID, current options and focus. A long Execute command is compared with Droid’s approval detail. A literal two-file `git apply` request is backed by bounded, rechecked patch bytes. The sampled always-allow option selected Low autonomy in the running session. A separate Linux account settings file retained its Off default. The native card uses Droid’s own choice text. A real enforced policy block left the target file absent. Factory recorded the rule and reason in its transcript and printed them in the terminal. A Script-wrapped MCP prompt in 1.21.1 exposed no separate matching inner call ID in its transcript or sampled hooks. That prompt is handled in its terminal. No separate sandbox permission or account-level quota was induced. The stale-card test covers a completed desktop answer, a repeated tap and separate call IDs. The terminal transports do not supply a cross-client atomic compare-and-answer receipt for a desktop key arriving between the final screen read and the device key.
- **Session changes.** Herdr 0.9.5 could keep reporting the original `herdr:droid` after a desktop `/new`. The Host probe checks foreground process start and the Factory controller against the session header. A fork can create a transcript while the original controller remains active. On the sampled conversations `/clear` selected a new UUID, while `/compress` kept the UUID after confirmation. The matrix attributes these observations to the tested CLI workflow.
- **Background work.** Execute launch, parent reply, process exit and asynchronous child report have independent records. Command identity includes its tool call, PID and command. Rex can clip both the task list and its detail at 80 columns. Chat can inspect a uniquely identified row and offers the terminal if its full command cannot be rechecked. Separate real tmux runs on both systems recorded the parent reply and a background command exiting with code 7 under its own call ID. No targeted sub-Droid cancellation was demonstrated. Task outcomes with insufficient identity remain at their last reported state.
- **Other interfaces.** In Linux tmux, Enter submitted a steering message to the same session. Ctrl+Enter queued two messages. Ctrl+X cleared the whole queue before either was recorded. The queue screen supplied no stable item ID, so its native controls could not distinguish phone and desktop entries. Steering and queue management stay in the terminal. The native input guard was checked against recorded menu, Bash, side-chat and login frames. The Mission picker and its local startup screen were observed. Droid described an autonomous run with substantial credit use and requested separate confirmation, which was left at the prompt. No live worker, milestone or waiting-for-input state is asserted.
- **Device layout.** Native SwiftUI cards were rendered in a visible hosted simulator window on both device sizes. The captures cover the linked worktree path, a long command, the file diff, AskUser and Spec. Approvals were driven through the same Chat stores and backend paths as the controls. Full-app navigation, physical-device touch input and OS process eviction have separate evidence requirements.
- **Backend isolation.** tmux observations used the saved executable and server socket, two independent servers with pane `%0`, and a replacement server. An attached 125 × 32 terminal client supplied the desktop comparison. The Droid Rex blocks reported their before/after size and owner, including a null owner when no desktop client owned the block. In the macOS Rex control-link suite, the before and after owner were both null and the complete size result was identical. Separate macOS and Linux runs attached an independent terminal client to the exact Droid block before starting the real three-backend test. During checked Send, a session switch and Stop, the full size response and the non-null owner were sampled repeatedly on the same control connection. Separate live nested tmux servers exposed the same Droid screen on both panes. The outer foreground program was a tmux client, and its pane and server were distinguished from the inner Droid. Shared checked-typing tests cover reused numbers, a replaced Rex process/server and nested terminal scopes. Rows for stale actions on a real restarted Host remain explicitly marked.
- **Hook lifecycle.** Herdr TUI uses its Droid integration. New Agent on core and tmux supplies process-only settings. Existing terminals can register the Python 3 hook in Chat and then restart or resume Droid. Tests exercised the earlier Heeler-owned settings format, repeat installation, removal, an existing unrelated hook and preserved arguments. The isolated Linux test disabled hooks, enabled them again and recovered the same UUID in a new process.

## Supplemental regression failures

The wider six-suite run executed 125 tests and failed two methods. `hostCapabilitiesOfferChatOnlyWhereItReads` expected Amp on a Herdr TUI Host with no known platform (two assertions). `statusTurnAndForegroundEventsEachCheckAgain` timed out on notification counts in its Claude Code core fixture (three assertions). Neither method exercised a Droid conversation. The five selected transport and capability suites passed all 80 tests. Both failing methods also reproduced on an isolated export of the starting commit before the Droid work. An earlier selector spelling matched no core test and is excluded from the passing runs.

## Reproducing the app checks

Use an authenticated disposable Factory account directory on each Host, the pinned SSH fixture for that Host and the independent HeelerLiveTests scheme. Supply the private fixture paths at runtime. Use these commands for the focused suite and the two primary live suites.

```sh
make test-app TEST_SELECTOR='HeelerTests/DroidChatTests'
TEST_RUNNER_HEELER_DROID_CHAT_LAB="$TUI_LAB" TEST_RUNNER_HEELER_DROID_SCENARIOS=1 \
  make test-app SCHEME=HeelerLiveTests TEST_SELECTOR='HeelerLiveTests/DroidChatLiveTests'
TEST_RUNNER_HEELER_DROID_BACKENDS_LAB="$BACKENDS_LAB" TEST_RUNNER_HEELER_DROID_BACKEND_SCENARIOS=1 \
  make test-app SCHEME=HeelerLiveTests TEST_SELECTOR='HeelerLiveTests/DroidBackendChatLiveTests'
```

The initial Linux backend attempt on this candidate found retired temporary terminal addresses. Its failing receipt is retained as `linux-backends-e43387060.txt`. The retry addressed fresh Droids on the same Linux installation. Each backend case exercised one real Host from the simulator. One intermediate retry preserved a previously prepared launch file (its final newline was missing), so core launched without the process hook. The final Linux run started with the exact previous Heeler-generated settings bytes. Receipts for the two preliminary attempts remain in the local evidence bundle. The counted method and its three arguments are reported separately. The original Herdr Stop check required the raw status Idle. Factory recorded an interrupted turn and returned its input box while Herdr reported Done. The corrected check accepts either idle status through the same app mapping, checks the visible input box, then switches to another UUID, attempts the stale Stop and interrupts the new turn with a fresh action. Its two reruns are listed separately. The initial macOS Spec handoff also timed out and left the original proposal displayed. A fresh native handoff then passed and followed the new UUID. The cause of that first timeout remains undetermined.

See the [Chat guide](../guides/chat.md), [test fixture contract](testing.md), [Droid reducer and input checks](../../Tests/HeelerTests/DroidChatTests.swift), [real Herdr dialog scenarios](../../Tests/HeelerLiveTests/DroidDialogLiveTests.swift), [three-backend checks](../../Tests/HeelerLiveTests/DroidBackendChatLiveTests.swift), [recorded terminal frames](../../Tests/HeelerTests/ChatFixtures/screens/droid), and [redacted transcript samples](../../Tests/HeelerTests/ChatFixtures/droid). Factory documents the CLI, permission model, hooks and Mission controls in its [CLI reference](https://docs.factory.com/droid-cli/cli-reference), [permission rules](https://docs.factory.com/autonomy-and-safety/permission-rules), [hook reference](https://docs.factory.com/harness/hooks), [AskUser reference](https://github.com/Factory-AI/factory/blob/main/docs/reference/ask-user-tool.mdx), [Spec Mode guide](https://docs.factory.com/autonomy-and-safety/specification-mode), [background subagents guide](https://docs.factory.com/harness/subagents) and [Mission Control guide](https://docs.factory.com/missions/running-cli).

The temporary local Linux container was removed after the tests. It had no persistent mounts. The isolated Mac backends, SSH fixtures and test simulators were stopped.
