# Rex daily workflow acceptance

The application candidate is **E = 4c07c2b34e7c5816631dbb2ff2f65484c8820879**. Herdr created a clean worktree from the execution-time origin/main at 10148154331e5496afaef9b5b450d514fd1d7d8e. Heeler 0.1.18 (43) connected to Herdr TUI 0.9.5 (protocol 22) and Rex 0.1.0-preview.25 (b070aae645f5). Rex advertised API 24 and negotiated API 19 with Heeler. A separate client negotiated revision 12. The POSIX Hosts ran macOS 27.0.1 (26A434) and Debian 12.15 arm64 (Linux 7.2.12-orbstack). Testing on November 27–28, 2026 used Xcode 27.2 (27B52) and iOS/iPadOS Simulator 27.0 (24A434).

**N** means native, **R** read-only, **T** terminal-only and **U** unavailable. Each result belongs to the exact application and Host named in its row. **PASS** requires an executed action and the corresponding observation, **FAIL** records an attempted action with an unmet expectation, and **NOT-RUN** records missing verification. **N/A** includes the reason. The Herdr column labels its reference run where it predates E. All Windows cells without a live native Windows Host remain NOT-RUN. Isolated SSH accounts with both multiplexers and Rex-only Hosts are identified separately. A plain socket, an SSH Store, a tap on a Simulator and a real notification delivery are distinct observations.

The [user entry and gap table](rex-daily-workflows.md) identifies the state owner and transport. The [E run manifest](evidence/rex-candidate/results.json) lists methods, actual counts, device UDIDs and bundle paths. [D matrix](rex-daily-acceptance-86f260495.md) · [C matrix](rex-daily-acceptance-b8af66cfd.md) · [App guide](../guides/rex.md) · [Chat](rex-chat-parity.md)
At the user-requested stop, 34 completed result bundles contained 49 executed methods (38 passed, 11 failed, zero skipped). Incomplete runners and zero-method launches do not qualify. The separate UI log contains 11 completed flows and six unfinished or unattempted flows. The 37 tooling checks and 31 focused Node checks completed. A full Node run before dependency installation failed during setup. Its post-install repeat was interrupted.


## Daily work

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Discover the running Server and accept its SSH identity | N NOT-RUN | N PASS (real account lookup and pinned SSH) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Set up a fresh Host with Rex as its only multiplexer | U N/A (this scenario requires the absence of Herdr on the Host) | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · Setup |
| Read the operating system, negotiated revision and program capabilities | R NOT-RUN | R PASS (capability sheet with the negotiated API and selected Host) | R PASS (capability sheet with the negotiated API and selected Host) | R NOT-RUN | E · [Simulator](evidence/rex-daily-simulator-4c07c2b34.json) |
| Connect on SSH, distinguish missing socket and refused forwarding | N NOT-RUN | N PASS (pinned SSH, running and absent sockets, refused forwarding) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Refresh Workspace, Tab and Pane inventory and follow an independent change | N NOT-RUN | N PASS (native refresh, checked against Rex) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| New Terminal in a selected directory and return to the desktop | N PASS (macOS and Linux) (reference run) | N PASS | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Choose a Tab label at creation | N PASS (macOS and Linux) (reference run) | N PASS | N NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Create an isolated Workspace | N PASS (macOS and Linux) (reference run) | N PASS | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Start an Agent in the directory of the focused split | N NOT-RUN | N PASS (real foreground PID and cwd) | N NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| New Agent with directory, executable, preset, account and literal arguments | N PASS (macOS and Linux) (reference run) | N PASS (preset and linked checkout independently checked, management label changed) | N NOT-RUN | U NOT-RUN | E · [Simulator](evidence/rex-daily-simulator-4c07c2b34.json) |
| Start in a new Git worktree and branch | N PASS (macOS and Linux) (reference run) | N PASS (preset and linked checkout independently checked, management label changed) | N NOT-RUN | U NOT-RUN | E · [Simulator](evidence/rex-daily-simulator-4c07c2b34.json) |
| Inspect a linked checkout, its branch and its Git changes | R PASS (macOS and Linux) (reference run) | R PASS | R NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Review and remove an existing worktree from its detail | N PASS (macOS and Linux) (reference run) | T PASS (clean checkout removed in the neighboring Terminal; branch and source edits survived) | T NOT-RUN | T NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Rename a Workspace; check the persistent server label | N NOT-RUN | N PASS | N NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Change or clear the Agent management name | N NOT-RUN | N PASS (preset and linked checkout independently checked, management label changed) | N NOT-RUN | U NOT-RUN | E · [Simulator](evidence/rex-daily-simulator-4c07c2b34.json) |
| Clear the management name and recover the default | N NOT-RUN | N PASS | N NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Keep the foreground title when changing the management name | N NOT-RUN | N PASS | N NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Change the ongoing harness conversation title | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · Objects |
| Exit the chosen shell and recheck its neighbor and desktop focus | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · Objects |
| Close a selected Agent, Pane or Tab from a native menu | N PASS (macOS and Linux) (reference run) | U NOT-RUN (protocol lacks an atomic foreground precondition) | U NOT-RUN (protocol lacks an atomic foreground precondition) | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Move a Pane or Tab to another Workspace from Heeler | N NOT-RUN | U NOT-RUN (protocol lacks an atomic foreground precondition) | U NOT-RUN (protocol lacks an atomic foreground precondition) | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Read the current Workspace, Tab and Pane structure | R NOT-RUN | R PASS (session, active window and blocks) | R NOT-RUN | R NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Object and focus checks](rex-object-operations.md) |
| Rearrange a live split without changing desktop focus | U NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · Objects |
| Take a visible terminal’s grid, rotate and release ownership | N NOT-RUN | N PASS (visible Terminal acquired and returned size on the Rex-only Host); N NOT-RUN (rotation) | N PASS (visible Terminal acquired and returned size on the Rex-only Host); N NOT-RUN (rotation) | N NOT-RUN | E · [Simulator](evidence/rex-daily-simulator-4c07c2b34.json) |
| Use Chat while the independently attached desktop keeps its viewport | N NOT-RUN | N PASS (two independent desktop owners and grids) | N PASS (two independent desktop owners and grids) | N NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Drop and reconnect SSH to the same server instance | N NOT-RUN | N PASS (real SSH cut, restart with restored IDs, replacement at the same socket) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Restart the server, restore the original IDs and reject the old foreground | N NOT-RUN | N PASS (real SSH cut, restart with restored IDs, replacement at the same socket) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Replace the server at the same address and reject the old object | N NOT-RUN | N PASS (real SSH cut, restart with restored IDs, replacement at the same socket) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Foreground executable exits or the original block disappears | N NOT-RUN | N PASS (rebuilt block and shell reject departed input) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Keep the desktop shell editor and the phone draft after the Agent exits between paste and Enter | N NOT-RUN | N PASS (zero trailing keys, mobile draft restored, desktop buffers 84/84 and 79/79 bytes) | N PASS (zero trailing keys, mobile draft restored, both shell editors intact) | N NOT-RUN | E · [macOS production Store](evidence/rex-candidate/mac-terminal-handover.json) · [Debian live test](evidence/rex-candidate/linux-terminal-handover.json) |
| Rebuild a block in the same session and refuse input from the old object | N NOT-RUN | N PASS (rebuilt block and shell reject departed input) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Browse files and read selected bytes in their original directory | R NOT-RUN | R PASS (SFTP bytes from selected file) | R NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Read tracked and untracked patches | R NOT-RUN | R PASS (tracked and untracked Git patch) | R NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Read a discovered skill and insert its invocation into an unsent draft | N NOT-RUN | R PASS (catalog and document); N NOT-RUN (insert into draft) | N NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Hand Off to a sibling Agent; stage the source while both transcripts stay unchanged | N PASS (macOS and Linux) (reference run) | N NOT-RUN | N NOT-RUN | U NOT-RUN | E · Services |
| List GitHub items and open an item through the Host gh executable | R PASS (macOS and Linux) (reference run) | R NOT-RUN | R NOT-RUN | U NOT-RUN | E · Services |
| Send a GitHub issue comment and read it back | N NOT-RUN | N NOT-RUN | N NOT-RUN | U NOT-RUN | E · Services |
| Approve a pull request from the GitHub page | N NOT-RUN | N NOT-RUN | N NOT-RUN | U NOT-RUN | E · Services |
| Merge a pull request from the GitHub page | N NOT-RUN | N NOT-RUN | N NOT-RUN | U NOT-RUN | E · Services |
| List a listening port and load its HTTP page over SSH | N NOT-RUN | N PASS (HTTP body over the forwarded port) | N NOT-RUN | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Receive per-Host usage figures on this machine | R NOT-RUN | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Receive a live banner and tap the exact Agent | N NOT-RUN | N NOT-RUN | N PASS (Blocked tap opened its Pi); N NOT-RUN (Done tap interrupted) | U NOT-RUN | E · [Event and recipient](evidence/rex-daily-simulator-4c07c2b34.json) |
| Repeated status, disabled Host and departed recipient | N NOT-RUN | N NOT-RUN | N PASS (two Blocked events one banner, disabled Host silent); N NOT-RUN (last opt-out stage) | U NOT-RUN | E · [Event and recipient](evidence/rex-daily-simulator-4c07c2b34.json) |
| Receive and tap a real notification while Heeler is suspended | N NOT-RUN | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Send an encrypted status notification to a private registration and local relay | N PASS (macOS private encrypted relay); N NOT-RUN (Linux) (reference run) | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Start/update an activity on the physical Lock Screen | N NOT-RUN | U NOT-RUN (no Rex publisher or reachable physical device) | U NOT-RUN (no Rex publisher or reachable physical device) | U NOT-RUN | E · [Physical device availability](evidence/rex-candidate/physical-availability.json) · [Host requirements](rex-host-services-parity.md) |
| View a Rex-only Host reading in a Usage widget | R NOT-RUN (shared Herdr Host readings) | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN (no Rex-only background publisher) | U NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) · [Host services and fixtures](rex-host-services-parity.md) |
| Use long paths and controls on a narrow iPhone | N NOT-RUN | N NOT-RUN | N PASS (actual half-width iPad window or narrow iPhone on Rex-only Host) | N NOT-RUN | E · [Simulator](evidence/rex-daily-simulator-4c07c2b34.json) |
| Use columns inside the iPad app | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · Screens |
| Use Heeler in an actual half-width iPadOS window | N NOT-RUN | N PASS (actual half-width iPad window or narrow iPhone on Rex-only Host) | N NOT-RUN | N NOT-RUN | E · [Simulator](evidence/rex-daily-simulator-4c07c2b34.json) |
| Use the correct terminal for an Unknown status approval or Stop | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · Chat |
| Answer at most one of two identical prompts, including double-tap and unknown receipt | N NOT-RUN | N PASS (Codex lost response); N FAIL (Claude first held-card attempt) | N NOT-RUN | N NOT-RUN | E · [Action receipts](evidence/rex-candidate/mac-foreground-attempts.json) |
| Recover text and a staged attachment after a lost submit receipt | N NOT-RUN | N PASS (Enter accepted, response dropped, text and attachments recovered) | N NOT-RUN | N NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |

## Claude Code 2.1.332

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Claude Code – Bind the correct active conversation | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Claude Code – Read the identified history | R NOT-RUN | R NOT-RUN | R NOT-RUN | R NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Claude Code – Send multiline text and read one reply | N NOT-RUN | N FAIL (first integrated run did not complete the native send scenario) | N FAIL (first integrated run did not complete the native send scenario) | N NOT-RUN | E · [macOS](evidence/rex-candidate/mac-foreground-attempts.json) · [Debian](evidence/rex-candidate/linux-foreground-attempts.json) |
| Claude Code – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Answer a matched tool approval | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Claude Code – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Confirm a plan or send feedback | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Claude Code – Stop only the current foreground turn | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Claude Code – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | R NOT-RUN | E · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Claude Code – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | E · 2.1.332 · [Chat](rex-chat-parity.md) |

## Codex 0.172.0

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Codex – Bind the correct active conversation | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Codex – Read the identified history | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Codex – Send multiline text and read one reply | N NOT-RUN | N FAIL (first integrated run did not complete the native send scenario) | N FAIL (first integrated run did not complete the native send scenario) | T NOT-RUN | E · [macOS](evidence/rex-candidate/mac-foreground-attempts.json) · [Debian](evidence/rex-candidate/linux-foreground-attempts.json) |
| Codex – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Answer a matched tool approval | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Codex – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Codex – Stop only the current foreground turn | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Codex – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | E · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Codex – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 0.172.0 · [Chat](rex-chat-parity.md) |

## Pi 1.5.2

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Pi – Bind the correct active conversation | N NOT-RUN (macOS); N PASS (Debian Store, two real Pi clients) (reference run) | N NOT-RUN | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Pi – Read the identified history | R NOT-RUN (macOS); R PASS (Debian Store, two real Pi clients) (reference run) | R NOT-RUN | R PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Pi – Send multiline text and read one reply | N NOT-RUN (macOS); N PASS (Debian Store, two real Pi clients) (reference run) | N FAIL (first integrated run did not complete the native send scenario) | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [macOS](evidence/rex-candidate/mac-foreground-attempts.json) · [Debian](evidence/rex-candidate/linux-foreground-attempts.json) |
| Pi – Answer initial directory trust | T NOT-RUN | T NOT-RUN (stock CLI has no Heeler card for this action) | T NOT-RUN (stock CLI has no Heeler card for this action) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Pi – Answer a matched tool approval | T NOT-RUN | T NOT-RUN (stock CLI has no Heeler card for this action) | T NOT-RUN (stock CLI has no Heeler card for this action) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Pi – Answer a program question | T NOT-RUN | T NOT-RUN (stock CLI has no Heeler card for this action) | T NOT-RUN (stock CLI has no Heeler card for this action) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Pi – Confirm a plan or send feedback | U N/A (stock Pi 1.5.2 has no plan mode) | U N/A (stock Pi 1.5.2 has no plan mode) | U N/A (stock Pi 1.5.2 has no plan mode) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Pi – Send a staged attachment in native Chat | N NOT-RUN | N PASS (staged file and image, A received the prompt once, ambiguous receipt) | N NOT-RUN | T NOT-RUN | E · [Executed methods and devices](evidence/rex-candidate/results.json) |
| Pi – Stop only the current foreground turn | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | E · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N NOT-RUN | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Pi – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.5.2 · [Chat](rex-chat-parity.md) |

## Oh My Pi 18.12.3

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Oh My Pi – Bind the correct active conversation | N NOT-RUN (macOS); N PASS (Debian, two real clients) (reference run) | N NOT-RUN | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Oh My Pi – Read the identified history | R NOT-RUN (macOS); R PASS (Debian, two real clients) (reference run) | R NOT-RUN | R PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Oh My Pi – Send multiline text and read one reply | N NOT-RUN (macOS); N PASS (Debian, two real clients) (reference run) | N FAIL (first integrated run did not complete the native send scenario) | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [macOS](evidence/rex-candidate/mac-foreground-attempts.json) · [Debian](evidence/rex-candidate/linux-foreground-attempts.json) |
| Oh My Pi – Answer initial directory trust | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Answer a matched tool approval | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Stop only the current foreground turn | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N NOT-RUN | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Oh My Pi – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 18.12.3 · [Chat](rex-chat-parity.md) |

## Factory Droid 1.21.1

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Factory Droid – Bind the correct active conversation | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Read the identified history | R NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | R NOT-RUN | R NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Send multiline text and read one reply | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.21.1 · [Chat](rex-chat-parity.md) |
| Factory Droid – Answer initial directory trust | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Answer a matched tool approval | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Answer a program question | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Confirm a plan or send feedback | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.21.1 · [Chat](rex-chat-parity.md) |
| Factory Droid – Stop only the current foreground turn | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Inspect individual background work and later results | R PASS (macOS and Debian, default model Script records on two reopens, E) | R PASS (two independent finished commands and exit codes 0/17), R FAIL (initial running read timed out) | R PASS (two independent finished commands and exit codes 0/17), R PASS (both commands while running) | T NOT-RUN | E · [macOS](evidence/rex-candidate/mac-factory-finished.json) · [Debian](evidence/rex-candidate/linux-factory-finished.json) |
| Factory Droid – Stop a selected background job | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | T NOT-RUN (nested Script jobs are read-only in Chat) | T NOT-RUN (nested Script jobs are read-only in Chat) | T NOT-RUN | E · [Factory event identity and plan](droid-chat-validation.md) |
| Factory Droid – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Reopen the same conversation after detaching or reconnecting | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Factory Droid – Open the sign-in screen on the selected Agent terminal | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |

## Devin CLI 3000.15.14

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Devin CLI – Bind the correct active conversation | N PASS (macOS and Linux) (reference run) | N NOT-RUN | N PASS (signed-in Rex Store, exact Agent and official thread) | T NOT-RUN | E · [Six signed-in scenarios](evidence/rex-candidate/linux-signed-devin.json) |
| Devin CLI – Read the identified history | R PASS (macOS and Linux) (reference run) | R NOT-RUN | R PASS (signed-in Rex Store, exact Agent and official thread) | T NOT-RUN | E · [Six signed-in scenarios](evidence/rex-candidate/linux-signed-devin.json) |
| Devin CLI – Send multiline text and read one reply | N PASS (macOS and Linux) (reference run) | N FAIL (staged submission exceeded the bound, official thread had zero new entries) | N PASS (signed-in Rex Store, exact Agent and official thread) | T NOT-RUN | E · [Run manifest](evidence/rex-candidate/results.json) |
| Devin CLI – Answer initial directory trust | N NOT-RUN (macOS); N PASS (Debian accept, decline, then stale tap) (reference run) | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Devin CLI – Answer a matched tool approval | N PASS (macOS and Linux, fresh long-command and card runs) (reference run) | N NOT-RUN | N PASS (signed-in Rex Store, exact Agent and official thread) | T NOT-RUN | E · [Six signed-in scenarios](evidence/rex-candidate/linux-signed-devin.json) |
| Devin CLI – Answer a program question | N PASS (macOS and Linux) (reference run) | N NOT-RUN | N PASS (signed-in Rex Store, exact Agent and official thread) | T NOT-RUN | E · [Six signed-in scenarios](evidence/rex-candidate/linux-signed-devin.json) |
| Devin CLI – Confirm a plan or send feedback | N PASS (Debian decline and feedback); N NOT-RUN (macOS) (reference run) | N NOT-RUN | N PASS (signed-in Rex Store, exact Agent and official thread); N FAIL (first plan attempt) | T NOT-RUN | E · [Six signed-in scenarios](evidence/rex-candidate/linux-signed-devin.json) |
| Devin CLI – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 3000.15.14 · [Chat](rex-chat-parity.md) |
| Devin CLI – Stop only the current foreground turn | N PASS (macOS fresh session and Linux) (reference run) | N NOT-RUN | N PASS (two distinct signed turns interrupted. A stale Stop was refused) | T NOT-RUN | E · [Official interruptions](evidence/rex-candidate/linux-devin-stop.json) |
| Devin CLI – Inspect individual background work and later results | R PASS (macOS and Debian, fresh retries) (reference run) | N FAIL (first Composer attempt remained in its editor, zero official calls or tasks) | N PASS (three mobile requests, exit 0 and 17, 12,323 failure bytes, later child report, two reopens) | T NOT-RUN | E · [macOS attempt](evidence/rex-candidate/mac-devin-first-background.json) · [Debian jobs and child](evidence/rex-candidate/linux-devin-background.json) |
| Devin CLI – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 3000.15.14 · [Chat](rex-chat-parity.md) |
| Devin CLI – Refuse stale input after a desktop session switch and recover the draft | N PASS (macOS fresh session and Debian) (reference run) | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Devin CLI – Reopen the same conversation after detaching or reconnecting | N PASS (macOS and Linux) (reference run) | N NOT-RUN | R PASS (same two jobs and child on two genuine reopens) | T NOT-RUN | E · [Debian jobs and child](evidence/rex-candidate/linux-devin-background.json) |

## Grok Build 1.0.92

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Grok Build – Bind the correct active conversation | N NOT-RUN (macOS); N PASS (Debian, actual Grok clients) (reference run) | N PASS (A and successor observed, peer B unchanged) | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Grok Build – Read the identified history | R NOT-RUN (macOS); R PASS (Debian, actual Grok clients) (reference run) | R PASS (A and successor observed, peer B unchanged) | R PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Grok Build – Send multiline text and read one reply | N NOT-RUN (macOS); N PASS (Debian, actual Grok clients) (reference run) | N PASS (A and successor observed, peer B unchanged) | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Grok Build – Answer initial directory trust | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Answer a matched tool approval | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Stop only the current foreground turn | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| Grok Build – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N PASS (A and successor observed, peer B unchanged) | N PASS (A and successor observed, peer B unchanged) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Grok Build – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | E · 1.0.92 · [Chat](rex-chat-parity.md) |

## OpenCode 2.0.32

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| OpenCode – Bind the correct active conversation | N NOT-RUN | R PASS (explicit history choice); U NOT-RUN (active writer) | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Read the identified history | R NOT-RUN | R PASS (two independently identified histories) | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Send multiline text and read one reply | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |
| OpenCode – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Answer a matched tool approval | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Answer a program question | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Send a staged attachment in native Chat | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Stop only the current foreground turn | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Inspect individual background work and later results | R NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | R NOT-RUN (explicit history only) | R NOT-RUN (explicit history only) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| OpenCode – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | R NOT-RUN (explicit history only) | R NOT-RUN (explicit history only) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |

## Antigravity CLI 1.5.18

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Antigravity CLI – Bind the correct active conversation | N NOT-RUN | T NOT-RUN | N PASS (bound text; original draft restored after returning to its UUID) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Read the identified history | R NOT-RUN | T NOT-RUN | R PASS (bound text; original draft restored after returning to its UUID) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Send multiline text and read one reply | N NOT-RUN | T NOT-RUN | N PASS (bound text; original draft restored after returning to its UUID) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Answer a matched tool approval | N NOT-RUN | T NOT-RUN | T PASS (authentic Run Command / Allow dialog opened in its own terminal; no answer sent) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Answer a program question | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Send a staged attachment in native Chat | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Stop only the current foreground turn | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Inspect individual background work and later results | R NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | T NOT-RUN | N PASS (bound text; original draft restored after returning to its UUID) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | T NOT-RUN | N PASS (bound text; original draft restored after returning to its UUID) | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Antigravity CLI – Open the sign-in screen on the selected Agent terminal | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |

## Amp 0.0.1795737653-g84af98

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Amp – Bind the correct active conversation | N NOT-RUN | R PASS (installed plugin, official threads, selected foreground and reopen) | R NOT-RUN (requires installed plugin) | T NOT-RUN | E · [macOS reader](evidence/rex-candidate/mac-amp-reader.json) · [macOS Terminal](evidence/rex-candidate/mac-amp-terminal.json) · [Debian Terminal](evidence/rex-candidate/linux-amp-terminal.json) |
| Amp – Read the identified history | R NOT-RUN | R PASS (installed plugin, official threads, selected foreground and reopen) | R NOT-RUN (requires installed plugin) | T NOT-RUN | E · [macOS reader](evidence/rex-candidate/mac-amp-reader.json) · [macOS Terminal](evidence/rex-candidate/mac-amp-terminal.json) · [Debian Terminal](evidence/rex-candidate/linux-amp-terminal.json) |
| Amp – Send multiline text and read one reply | N NOT-RUN | T PASS (the selected Amp Terminal submitted one marked message; adjacent thread unchanged) | T PASS (the selected Amp Terminal submitted one marked message; adjacent thread unchanged) | T NOT-RUN | E · [macOS reader](evidence/rex-candidate/mac-amp-reader.json) · [macOS Terminal](evidence/rex-candidate/mac-amp-terminal.json) · [Debian Terminal](evidence/rex-candidate/linux-amp-terminal.json) |
| Amp – Answer initial directory trust | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Answer a matched tool approval | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Answer a program question | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Send a staged attachment in native Chat | T NOT-RUN (Amp Chat hides the native file picker) | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Stop only the current foreground turn | T NOT-RUN (Amp Chat has no native Stop) | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Inspect individual background work and later results | T NOT-RUN (the plugin pages messages and tool results) | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Harness evidence](rex-chat-parity.md) · [Test results](evidence/rex-candidate/results.json) |
| Amp – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | R PASS (installed plugin, official threads, selected foreground and reopen) | T NOT-RUN | T NOT-RUN | E · [macOS reader](evidence/rex-candidate/mac-amp-reader.json) · [macOS Terminal](evidence/rex-candidate/mac-amp-terminal.json) · [Debian Terminal](evidence/rex-candidate/linux-amp-terminal.json) |
| Amp – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | R PASS (installed plugin, official threads, selected foreground and reopen) | R NOT-RUN (requires installed plugin) | T NOT-RUN | E · [macOS reader](evidence/rex-candidate/mac-amp-reader.json) · [macOS Terminal](evidence/rex-candidate/mac-amp-terminal.json) · [Debian Terminal](evidence/rex-candidate/linux-amp-terminal.json) |
| Amp – Open the sign-in screen on the selected Agent terminal | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | E · [Foreground identity and program controls](rex-chat-parity.md) |

### Remaining boundaries

Rex revisions 12–19 lack a conditional destructive operation against the current foreground epoch. The server ignored an expected-foreground field and closed a different process; moving a block could also change desktop focus. Cross-session transfer requires revision 22. These native actions stay gated. The supported user route for ending a shell is its visible Terminal. An empty Rex session can remain after the last shell exits. [Real protocol observations and upstream requirements](rex-object-operations.md)

Heeler rechecks the current server, block, foreground program, session and prompt or turn before an effect. It serializes its own inputs. A desktop participant could still act after the final read and before the server applies a key. A server-side conditional write would close that interval. Unknown status limits native Stop and Blocked Cards. The targeted Terminal remains available. [Chat behavior and stale input](rex-chat-parity.md)

Rex-only usage, background push and the Lock Screen need a persistent publisher, registration and delivery. The per-device foreground banner consumes connected Rex status and the configured preference. A private Herdr relay establishes encrypted delivery to that relay. It does not exercise physical APNs or ActivityKit. [Host integrations and installation scope](rex-host-services-parity.md)
