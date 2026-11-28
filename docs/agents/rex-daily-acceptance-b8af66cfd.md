# Rex daily workflow acceptance on b8af66cfd

The frozen application candidate is **S = b8af66cfd488a20062147e174b00009b6ebd1a54**, based on origin/main `10148154331e5496afaef9b5b450d514fd1d7d8e`. The baseline worktree was clean. Heeler 0.1.18 (43) ran on iOS and iPadOS 27.0 Simulators built with Xcode 27.2 (27B52). The reference is Herdr TUI 0.9.5, protocol 22. The Rex Hosts ran preview.25 (b070aae645f5, native API 24), on macOS 27.0.1 arm64 or Debian 12.15 arm64. The app negotiated revision 19. Independent protocol clients exercised revision 12 on the same binary. The tested Linux kernel was 7.2.12-orbstack. The Rex-only macOS test used a private SSH login on a shared machine. The Debian Rex-only test used its own container. No native Windows Host was connected.

Each cell gives the user control and its observed result. **N** is a native operation, **R** is read-only, **T** is terminal-only, and **U** is unavailable. **PASS** requires the scenario on the named backend and Host with S, or an explicitly identified Herdr baseline run on the pinned origin/main. **FAIL** records a tried scenario that missed its expected result. **NOT-RUN** means there is no qualifying run on S, including cases with earlier evidence. **N/A** is used only where the scenario is inapplicable and the reason is stated. A raw socket test, a production Store over pinned SSH, a Simulator UI action and a physical notification are distinguished in the evidence. A terminal-only pass establishes the terminal route only. A single Herdr result applies to its named Host. When shown as two results, macOS comes first.

[Workflow and source map](rex-daily-workflows.md) · [Per-run counts and devices](evidence/rex-daily/results.json) · [Simulator observations](rex-simulator-acceptance.md) · [Rex wire and Linux versions](rex-linux-lab.md)

The [iPhone read-only history](evidence/rex-daily/iphone-opencode-history.png) shows both the terminal and history selection actions. The [iPad system window](evidence/rex-daily/ipad-half-width-terminal.png) shows the full display around the 561.5 pt Heeler window and its active terminal shortcuts.

### Reading the evidence column

- **Setup**, **Screens** and **Notifications** use the [GUI evidence](rex-simulator-acceptance.md), the [macOS login inventory](evidence/rex-daily/mac-rex-only.json) and the [Debian container inventory](evidence/rex-daily/linux-rex-only.json).
- **Objects**, **Inventory**, **Terminal**, **SSH** and **Recovery** map to the named RexProject, Inventory, Terminal, SSH and Recovery suites in the [candidate test record](evidence/rex-daily/results.json). Layout, move and close protocol behavior is recorded separately. [Real two-client probes](rex-object-operations.md)
- **Host reads**, **Services** and **Integrations** follow the production Host services. The GitHub fixture used the actual gh CLI against a private HTTPS endpoint. [Service boundaries and independent receipts](rex-host-services-parity.md)
- **Chat** specifies the running CLI and per-harness evidence. The loopback providers supplied controlled replies and held streams behind real locally installed CLIs. Devin and Factory account-dependent paths are identified separately. [Chat evidence](rex-chat-parity.md) · [Historical Droid matrix](droid-chat-validation.md) · [Historical Devin matrix](devin-chat-validation.md)

The baseline Rex Console and Rex Chat Typing suites executed 43 methods at 10148154, with 43 passes and zero skips. The baseline Simulator report separately records actual Herdr and Rex UI actions. The historical Droid and Devin observations name different commits and are linked for comparison. Detailed run names in the evidence distinguish a live production entry from a fake or a direct wire observation.

The matching device inventory, 33 GUI observations and screenshot hashes for this app are in the [Simulator manifest](evidence/rex-daily-simulator-b8af66cfd.json). The two tests whose original terminal presentation differed from their fixtures use the supplemental driver fingerprints below. A standard Make build of the amended tests produced the [same application digest](evidence/rex-daily/same-runtime-test-build.json).

The first frozen run recorded 69 completed result bundles including retries. Each result counts executed methods. Raw socket, SSH Store and UI-driver runs are identified in the manifest. The independent Herdr Store drivers are recorded separately in the program rows.

## Daily work

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Discover the running Server and accept its SSH identity | N NOT-RUN | N PASS | N PASS | N NOT-RUN | S · Setup |
| Set up a fresh Host with Rex as its only multiplexer | U N/A (this scenario requires the absence of Herdr on the Host) | N PASS (private login, discovery and actual Pi A/B); N PASS (pure Host projects) | N PASS (exclusive container, actual Pi A/B and new shell); N PASS (pure Host projects) | N NOT-RUN | S · [Debian executables and live socket census](evidence/rex-daily/linux-rex-only-tools.json) · [macOS restricted login](evidence/rex-daily/mac-rex-only.json) |
| Read the operating system, negotiated revision and program capabilities | R NOT-RUN | R PASS (API 19, programs, OpenCode read-only) | R PASS (API 19, programs, OpenCode read-only) | R NOT-RUN | S · [Add Host and preflight](rex-simulator-acceptance.md) |
| Connect on SSH, distinguish missing socket and refused forwarding | N NOT-RUN | N PASS (same socket spelling); N FAIL (symlink spelling on refusal) | N PASS | N NOT-RUN | S · SSH |
| Refresh Workspace, Tab and Pane inventory and follow an independent change | N NOT-RUN | N PASS | N PASS | N NOT-RUN | S · Inventory |
| New Terminal in a selected directory and return to the desktop | N PASS (macOS and Linux) | N PASS | N PASS | N NOT-RUN | S · Objects |
| Choose a Tab label at creation | N PASS (macOS and Linux) | N PASS | N PASS | U NOT-RUN | S · Objects |
| Create an isolated Workspace | N PASS (macOS and Linux) | N PASS | N PASS | N NOT-RUN | S · Objects |
| Start an Agent in the directory of the focused split | N NOT-RUN | N PASS (fresh pair and published-receipt driver); first driver FAIL | N PASS (mixed and pure Host with published-receipt driver); first pure driver FAIL | U NOT-RUN | S · [Later published Debian PID and cwd](evidence/rex-daily/linux-focused-receipt.json) · [Results](evidence/rex-daily/results.json) |
| New Agent with directory, executable, preset, account and literal arguments | N PASS (macOS and Linux) | N PASS | N PASS | U NOT-RUN | S · Objects |
| Start in a new Git worktree and branch | N PASS (macOS and Linux) | N PASS | N PASS | U NOT-RUN | S · [iPad linked checkout and clean branch](evidence/rex-daily/ipad-worktree-changes.png) · [Independent Git and Rex observations](rex-simulator-acceptance.md) |
| Inspect a linked checkout, its branch and its Git changes | R PASS (macOS and Linux) | R PASS | R PASS | U NOT-RUN | S · Objects |
| Review and remove an existing worktree from its detail | N PASS (macOS and Linux) | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · Objects |
| Rename a Workspace; check the persistent server label | N NOT-RUN | N PASS | N PASS | U NOT-RUN | S · Objects |
| Change or clear the Agent management name | N NOT-RUN | N PASS | N PASS | U NOT-RUN | S · Objects |
| Clear the management name and recover the default | N NOT-RUN | N PASS | N PASS | U NOT-RUN | S · Objects |
| Keep the foreground title when changing the management name | N NOT-RUN | N PASS | N PASS | U NOT-RUN | S · RexProjectLiveTests verifies the custom management name, its removal, and the preserved independent foreground title. |
| Change the ongoing harness conversation title | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · Objects |
| Exit the chosen shell and recheck its neighbor and desktop focus | N NOT-RUN | T PASS (explicit exit in the selected shell) | T PASS (new Bash exited; original PID 86 and both Pi peers unchanged) | T NOT-RUN | S · [New shell, marker and cwd, then terminal closure and neighbors](evidence/rex-daily/linux-iphone-shell-exit.json) · [macOS iPhone](rex-simulator-acceptance.md) |
| Close a selected Agent, Pane or Tab from a native menu | N PASS (macOS and Linux) | U NOT-RUN | U NOT-RUN | U NOT-RUN | S · Objects |
| Move a Pane or Tab to another Workspace from Heeler | N NOT-RUN | U NOT-RUN | U NOT-RUN | U NOT-RUN | S · Objects |
| Read the current Workspace, Tab and Pane structure | R NOT-RUN | R PASS | R PASS | R NOT-RUN | S · Inventory |
| Rearrange a live split without changing desktop focus | U NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · [Desktop focus and move probes](rex-object-operations.md). The desktop can rearrange a split. |
| Take a visible terminal’s grid, rotate and release ownership | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | S · Terminal |
| Use Chat while the independently attached desktop keeps its viewport | N NOT-RUN | N PASS | N PASS (real A/B with desktop connections) | N NOT-RUN | S · Terminal |
| Drop and reconnect SSH to the same server instance | N NOT-RUN | N PASS | N PASS | N NOT-RUN | S · Recovery |
| Restart the server, restore the original IDs and reject the old foreground | N NOT-RUN | N PASS | N PASS | N NOT-RUN | S · Recovery |
| Replace the server at the same address and reject the old object | N NOT-RUN | N PASS | N PASS | N NOT-RUN | S · Recovery |
| Foreground executable exits or the original block disappears | N NOT-RUN | N PASS | N PASS | N NOT-RUN | S · Recovery |
| Rebuild a block in the same session and refuse input from the old object | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | S · Recovery |
| Browse files and read selected bytes in their original directory | R NOT-RUN | R PASS | R PASS | U NOT-RUN | S · Host reads |
| Read tracked and untracked patches | R NOT-RUN | R PASS | R PASS | U NOT-RUN | S · [iPhone patch](evidence/rex-daily/iphone-changes.png) · [Production Host tests](evidence/rex-daily/results.json) |
| Read a discovered skill and insert its invocation into an unsent draft | N NOT-RUN | N PASS (read, then insert an unsent /heeler-lab-gui) | R PASS (catalog and document); N NOT-RUN (draft insertion) | U NOT-RUN | S · [iPhone keyboard, Files and Changes](rex-simulator-acceptance.md) · [Candidate test results](evidence/rex-daily/results.json) |
| Hand Off to a sibling Agent; stage the source while both transcripts stay unchanged | N PASS (macOS and Linux) | N PASS | N PASS | U NOT-RUN | S · Services |
| List GitHub items and open an item through the Host gh executable | R PASS (macOS and Linux) | R PASS | R PASS | U NOT-RUN | S · Services |
| Send a GitHub issue comment and read it back | N NOT-RUN | N NOT-RUN | N PASS (one private issue comment) | U NOT-RUN | S · [Count, response and independent readback](evidence/rex-daily/github-comment.json). The endpoint was private to the fixture. |
| Approve a pull request from the GitHub page | N NOT-RUN | N NOT-RUN | N NOT-RUN | U NOT-RUN | S · The Repository review action exists in [GitHub](rex-host-services-parity.md). Only a private issue comment was executed. |
| Merge a pull request from the GitHub page | N NOT-RUN | N NOT-RUN | N NOT-RUN | U NOT-RUN | S · The Repository merge action exists in [GitHub](rex-host-services-parity.md). The private fixture covers issue comments. |
| List a listening port and load its HTTP page over SSH | N NOT-RUN | N PASS | N PASS | U NOT-RUN | S · Host reads |
| Receive per-Host usage figures on this machine | R NOT-RUN | U NOT-RUN | U NOT-RUN | U NOT-RUN | S · Integrations |
| Receive a live banner and tap the exact Agent | N NOT-RUN | N PASS (Blocked 6.43 s and Done 10.66 s, same Pi) | N PASS (390 pt Blocked; iPad Blocked 5.72 s and Done 10.95 s) | U NOT-RUN | S · [iPhone alert](evidence/rex-daily/iphone-blocked-banner.png) · [Recipient and size owner](evidence/rex-daily/iphone-blocked-banner.json) · [iPad](rex-simulator-acceptance.md) |
| Repeated status, disabled Host and departed recipient | N NOT-RUN | N PASS (opt-out, departed recipient withdrew); N NOT-RUN (tap after withdrawal) | N PASS (duplicate Blocked, opt-out and restored preference) | U NOT-RUN | S · [Interactive notification checks](rex-simulator-acceptance.md) · [Repeated events and stale recipients](evidence/rex-daily/results.json) |
| Receive and tap a real notification while Heeler is suspended | N NOT-RUN | U NOT-RUN | U NOT-RUN | U NOT-RUN | S · Integrations |
| Send an encrypted status notification to a private registration and local relay | N PASS (macOS private encrypted relay); N NOT-RUN (Linux) | U NOT-RUN | U NOT-RUN | U NOT-RUN | S · Integrations |
| Start/update an activity on the physical Lock Screen | N NOT-RUN | U NOT-RUN | U NOT-RUN | U NOT-RUN | S · Integrations |
| View a Rex-only Host reading in a Usage widget | R NOT-RUN (shared Herdr Host readings) | U NOT-RUN | U NOT-RUN | U NOT-RUN | S · Integrations |
| Use long paths and controls on a narrow iPhone | N NOT-RUN | N PASS (390 pt creation, rotate and close shell) | N PASS (390 pt, pure Host setup); T PASS (fallback) | N NOT-RUN | S · Screens |
| Use columns inside the iPad app | N NOT-RUN | N PASS (named Workspace, worktree and keyboard) | N PASS (setup and native Chat in a real system window) | N NOT-RUN | S · Screens |
| Use Heeler in an actual half-width iPadOS window | N NOT-RUN | N PASS (561.5 × 744 pt; terminal Enter) | N PASS (561.5 × 744 pt, two native choices) | N NOT-RUN | S · Screens |
| Use the correct terminal for an Unknown status approval or Stop | N NOT-RUN | T NOT-RUN | T PASS (verified current terminal) | T NOT-RUN | S · [Rex status and chat policy](rex-chat-parity.md). Unowned or Unknown prompts open the selected Agent terminal. |
| Answer at most one of two identical prompts, including double-tap and unknown receipt | N NOT-RUN | N PASS (two requests, stale buttons; ambiguous receipt in FakeRexServer) | N PASS (Claude equal commands, separate calls; ambiguous receipt in FakeRexServer) | N NOT-RUN | S · [Selector and real foreground results](evidence/rex-daily/results.json). Duplicate gestures and dropped replies are also exercised in BlockedCardStoreTests. |
| Recover text and a staged attachment after a lost submit receipt | N NOT-RUN | N PASS (real Enter response dropped; Edit Draft) | N PASS (real Enter response dropped; Edit Draft) | N NOT-RUN | S · [Lost Enter and staged-file tests](evidence/rex-daily/results.json). The fault is applied only after the target Rex accepts Enter. |

## Claude Code 2.1.332

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Claude Code – Bind the correct active conversation | N NOT-RUN | N PASS | N PASS (same app; Linux glyph driver) | N NOT-RUN | S · 2.1.332 · [App and Linux driver fingerprints](evidence/rex-daily/linux-claude-driver.json) · [Both original and corrected runs](evidence/rex-daily/results.json) |
| Claude Code – Read the identified history | R NOT-RUN | R PASS | R PASS (same app; Linux glyph driver) | R NOT-RUN | S · 2.1.332 · [App and Linux driver fingerprints](evidence/rex-daily/linux-claude-driver.json) · [Both original and corrected runs](evidence/rex-daily/results.json) |
| Claude Code – Send multiline text and read one reply | N NOT-RUN | N PASS | N PASS (same app; Linux glyph driver) | N NOT-RUN | S · 2.1.332 · [App and Linux driver fingerprints](evidence/rex-daily/linux-claude-driver.json) · [Both original and corrected runs](evidence/rex-daily/results.json) |
| Claude Code – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Answer a matched tool approval | N NOT-RUN | N PASS | N PASS (same app; Linux glyph driver) | N NOT-RUN | S · 2.1.332 · [App and Linux driver fingerprints](evidence/rex-daily/linux-claude-driver.json) · [Both original and corrected runs](evidence/rex-daily/results.json) |
| Claude Code – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | S · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Confirm a plan or send feedback | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | S · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Send a staged attachment in native Chat | N NOT-RUN | N PASS | N PASS (same app; Linux glyph driver) | N NOT-RUN | S · 2.1.332 · [App and Linux driver fingerprints](evidence/rex-daily/linux-claude-driver.json) · [Both original and corrected runs](evidence/rex-daily/results.json) |
| Claude Code – Stop only the current foreground turn | N NOT-RUN | N PASS | N PASS (same app; Linux glyph driver) | N NOT-RUN | S · 2.1.332 · [App and Linux driver fingerprints](evidence/rex-daily/linux-claude-driver.json) · [Both original and corrected runs](evidence/rex-daily/results.json) |
| Claude Code – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | R NOT-RUN | S · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.1.332 · [Chat](rex-chat-parity.md) |
| Claude Code – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N PASS | N PASS (same app; Linux glyph driver) | N NOT-RUN | S · 2.1.332 · [App and Linux driver fingerprints](evidence/rex-daily/linux-claude-driver.json) · [Both original and corrected runs](evidence/rex-daily/results.json) |
| Claude Code – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | N NOT-RUN | S · 2.1.332 · [Chat](rex-chat-parity.md) |

## Codex 0.172.0

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Codex – Bind the correct active conversation | N NOT-RUN | N PASS | N PASS (worktree picker driver) | T NOT-RUN | S · 0.172.0 · [Three official Debian rollouts](evidence/rex-daily/linux-codex.json) · [Test-only driver](evidence/rex-daily/linux-codex-driver.json) · [macOS](evidence/rex-daily/mac-codex.json) |
| Codex – Read the identified history | R NOT-RUN | R PASS | R PASS (worktree picker driver) | T NOT-RUN | S · 0.172.0 · [Three official Debian rollouts](evidence/rex-daily/linux-codex.json) · [Test-only driver](evidence/rex-daily/linux-codex-driver.json) · [macOS](evidence/rex-daily/mac-codex.json) |
| Codex – Send multiline text and read one reply | N NOT-RUN | N PASS | N PASS (worktree picker driver) | T NOT-RUN | S · 0.172.0 · [Three official Debian rollouts](evidence/rex-daily/linux-codex.json) · [Test-only driver](evidence/rex-daily/linux-codex-driver.json) · [macOS](evidence/rex-daily/mac-codex.json) |
| Codex – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Answer a matched tool approval | N NOT-RUN | N PASS | N PASS (worktree picker driver) | T NOT-RUN | S · 0.172.0 · [Three official Debian rollouts](evidence/rex-daily/linux-codex.json) · [Test-only driver](evidence/rex-daily/linux-codex-driver.json) · [macOS](evidence/rex-daily/mac-codex.json) |
| Codex – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Send a staged attachment in native Chat | N NOT-RUN | N PASS | N PASS (worktree picker driver) | T NOT-RUN | S · 0.172.0 · [Three official Debian rollouts](evidence/rex-daily/linux-codex.json) · [Test-only driver](evidence/rex-daily/linux-codex-driver.json) · [macOS](evidence/rex-daily/mac-codex.json) |
| Codex – Stop only the current foreground turn | N NOT-RUN | N PASS | N PASS (worktree picker driver) | T NOT-RUN | S · 0.172.0 · [Three official Debian rollouts](evidence/rex-daily/linux-codex.json) · [Test-only driver](evidence/rex-daily/linux-codex-driver.json) · [macOS](evidence/rex-daily/mac-codex.json) |
| Codex – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | S · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.172.0 · [Chat](rex-chat-parity.md) |
| Codex – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N PASS | N PASS (worktree picker driver) | T NOT-RUN | S · 0.172.0 · [Three official Debian rollouts](evidence/rex-daily/linux-codex.json) · [Test-only driver](evidence/rex-daily/linux-codex-driver.json) · [macOS](evidence/rex-daily/mac-codex.json) |
| Codex – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 0.172.0 · [Chat](rex-chat-parity.md) |

## Pi 1.5.2

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Pi – Bind the correct active conversation | N NOT-RUN (macOS); N PASS (Debian Store, two real Pi clients) | N NOT-RUN | N PASS | T NOT-RUN | S · 1.5.2 · [macOS JSONL](evidence/rex-daily/mac-pi.json) · [Debian JSONL](evidence/rex-daily/linux-pi.json) |
| Pi – Read the identified history | R NOT-RUN (macOS); R PASS (Debian Store, two real Pi clients) | R NOT-RUN | R PASS | T NOT-RUN | S · 1.5.2 · [macOS JSONL](evidence/rex-daily/mac-pi.json) · [Debian JSONL](evidence/rex-daily/linux-pi.json) |
| Pi – Send multiline text and read one reply | N NOT-RUN (macOS); N PASS (Debian Store, two real Pi clients) | N NOT-RUN | N PASS | T NOT-RUN | S · [Herdr Debian](evidence/rex-daily/linux-herdr-pi.json) · [Rex-only macOS](evidence/rex-daily/mac-pure-pi.json) · [Rex-only Debian](evidence/rex-daily/linux-pure-pi.json) |
| Pi – Answer initial directory trust | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Answer a matched tool approval | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Answer a program question | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Confirm a plan or send feedback | U N/A (stock Pi 1.5.2 has no plan mode) | U N/A (stock Pi 1.5.2 has no plan mode) | U N/A (stock Pi 1.5.2 has no plan mode) | U NOT-RUN (no native Host) | S · 1.5.2 · The released coding-agent README identifies plan mode and subagents as opt-in extensions. [Versioned package](https://www.npmjs.com/package/@earendil-works/pi-coding-agent/v/1.5.2) |
| Pi – Send a staged attachment in native Chat | N NOT-RUN | N PASS (real file/image recorded, mobile receipt unknown) | N PASS (real file/image recorded, mobile receipt unknown) | T NOT-RUN | S · 1.5.2 · [macOS official Pi record](evidence/rex-daily/mac-pi-attachment.json) · [Debian official record](evidence/rex-daily/linux-pi-attachment.json) |
| Pi – Stop only the current foreground turn | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | S · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.2 · [Chat](rex-chat-parity.md) |
| Pi – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N NOT-RUN | N PASS | T NOT-RUN | S · 1.5.2 · [macOS JSONL](evidence/rex-daily/mac-pi.json) · [Debian JSONL](evidence/rex-daily/linux-pi.json) |
| Pi – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.5.2 · [Chat](rex-chat-parity.md) |

## Oh My Pi 18.12.3

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Oh My Pi – Bind the correct active conversation | N NOT-RUN (macOS); N PASS (Debian, two real clients) | N PASS (fresh pair) | N PASS | T NOT-RUN | S · 18.12.3 · [macOS JSONL](evidence/rex-daily/mac-omp.json) · [Debian JSONL](evidence/rex-daily/linux-omp.json) |
| Oh My Pi – Read the identified history | R NOT-RUN (macOS); R PASS (Debian, two real clients) | R PASS (fresh pair) | R PASS | T NOT-RUN | S · 18.12.3 · [macOS JSONL](evidence/rex-daily/mac-omp.json) · [Debian JSONL](evidence/rex-daily/linux-omp.json) |
| Oh My Pi – Send multiline text and read one reply | N NOT-RUN (macOS); N PASS (Debian, two real clients) | N PASS (fresh pair) | N PASS | T NOT-RUN | S · 18.12.3 · [Herdr Debian](evidence/rex-daily/linux-herdr-omp.json) · [Rex macOS](evidence/rex-daily/mac-omp.json) · [Rex Debian](evidence/rex-daily/linux-omp.json) |
| Oh My Pi – Answer initial directory trust | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Answer a matched tool approval | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Stop only the current foreground turn | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |
| Oh My Pi – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N PASS (fresh pair) | N PASS | T NOT-RUN | S · 18.12.3 · [macOS JSONL](evidence/rex-daily/mac-omp.json) · [Debian JSONL](evidence/rex-daily/linux-omp.json) |
| Oh My Pi – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 18.12.3 · [Chat](rex-chat-parity.md) |

## Factory Droid 1.21.1

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Factory Droid – Bind the correct active conversation | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Read the identified history | R NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | R NOT-RUN | R NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Send multiline text and read one reply | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Chat](rex-chat-parity.md) |
| Factory Droid – Answer initial directory trust | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Answer a matched tool approval | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Answer a program question | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Confirm a plan or send feedback | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Chat](rex-chat-parity.md) |
| Factory Droid – Stop only the current foreground turn | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Inspect individual background work and later results | R NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | R NOT-RUN | R NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Stop a selected background job | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Reopen the same conversation after detaching or reconnecting | N NOT-RUN (prior PASS on macOS/Linux, 4bf211cf2) | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.21.1 · [Prior cases and exact actions](droid-chat-validation.md) |
| Factory Droid – Open the sign-in screen on the selected Agent terminal | T NOT-RUN | T PASS (iPhone opened the actual device sign-in) | T PASS (iPhone opened the selected CLI sign-in) | T NOT-RUN | S · [Terminal observations by program](rex-chat-parity.md) |

## Devin CLI 3000.15.14

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Devin CLI – Bind the correct active conversation | N PASS (macOS and Linux) | N PASS | N PASS | T NOT-RUN | S · 3000.15.14 · [Signed-in behavior](rex-chat-parity.md) · [Candidate test results](evidence/rex-daily/results.json) |
| Devin CLI – Read the identified history | R PASS (macOS and Linux) | R PASS | R PASS | T NOT-RUN | S · 3000.15.14 · [Signed-in behavior](rex-chat-parity.md) · [Candidate test results](evidence/rex-daily/results.json) |
| Devin CLI – Send multiline text and read one reply | N PASS (macOS and Linux) | N PASS | N PASS | T NOT-RUN | S · 3000.15.14 · [Signed-in behavior](rex-chat-parity.md) · [Candidate test results](evidence/rex-daily/results.json) |
| Devin CLI – Answer initial directory trust | N NOT-RUN (macOS); N PASS (Debian accept, decline, then stale tap) | T NOT-RUN | T PASS (fresh Rex block reports Unknown) | T NOT-RUN | S · 3000.15.14 · [Herdr after decline](evidence/rex-daily/linux-herdr-devin-trust.json) · [Rex terminal and foreground](evidence/rex-daily/linux-devin-fresh-trust.json) |
| Devin CLI – Answer a matched tool approval | N PASS (macOS and Linux, fresh long-command and card runs) | N PASS | N PASS (owned complete card); T PASS (390 pt verification fallback) | T NOT-RUN | S · 3000.15.14 · [Visible terminal decision](evidence/rex-daily/iphone-terminal-approval.png) · [Exact file result](evidence/rex-daily/iphone-terminal-approval.json) |
| Devin CLI – Answer a program question | N PASS (macOS and Linux) | N PASS | N PASS (two native iPad answers; one official result) | T NOT-RUN | S · 3000.15.14 · [Half-width card](evidence/rex-daily/ipad-question-card.png) and [official result](evidence/rex-daily/ipad-devin-question.json) |
| Devin CLI – Confirm a plan or send feedback | N PASS (Debian decline and feedback); N NOT-RUN (macOS) | N PASS (decline, feedback, draft retained) | N FAIL (two fresh servers; protected paste before Enter) | T NOT-RUN | S · 3000.15.14 · [Backend-selectable test driver](evidence/rex-daily/rex-devin-plan-driver.json) · [Candidate test results](evidence/rex-daily/results.json) |
| Devin CLI – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 3000.15.14 · [Chat](rex-chat-parity.md) |
| Devin CLI – Stop only the current foreground turn | N PASS (macOS fresh session and Linux) | N PASS | N PASS (first turn interrupted); N FAIL (full two-turn check) | T NOT-RUN | S · 3000.15.14 · [Interrupted first turn and unsent second](evidence/rex-daily/linux-devin-stop.json) · [Candidate test results](evidence/rex-daily/results.json) |
| Devin CLI – Inspect individual background work and later results | R PASS (macOS and Debian, fresh retries) | R PASS (2 shells, 0/17; late child, 2 reopens) | R PASS (2 shells, 0/17; late child, 2 reopens) | T NOT-RUN | S · 3000.15.14 · [Herdr macOS](evidence/rex-daily/mac-herdr-devin-tasks.json) · [Rex macOS](evidence/rex-daily/mac-devin-tasks.json) · [Rex Debian](evidence/rex-daily/linux-devin-tasks.json) |
| Devin CLI – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 3000.15.14 · [Chat](rex-chat-parity.md) |
| Devin CLI – Refuse stale input after a desktop session switch and recover the draft | N PASS (macOS fresh session and Debian) | N PASS (parked drafts, desktop switch and resume) | N PASS (parked drafts, desktop switch and resume) | T NOT-RUN | S · 3000.15.14 · [Signed-in two-session behavior](rex-chat-parity.md) |
| Devin CLI – Reopen the same conversation after detaching or reconnecting | N PASS (macOS and Linux) | N PASS | N PASS | T NOT-RUN | S · 3000.15.14 · [Signed-in behavior](rex-chat-parity.md) · [Candidate test results](evidence/rex-daily/results.json) |

## Grok Build 1.0.92

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Grok Build – Bind the correct active conversation | N NOT-RUN (macOS); N PASS (Debian, actual Grok clients) | N PASS | N PASS | T NOT-RUN | S · 1.0.92 · [Bound and picked histories on both Hosts](evidence/rex-daily/results.json) |
| Grok Build – Read the identified history | R NOT-RUN (macOS); R PASS (Debian, actual Grok clients) | R PASS | R PASS | T NOT-RUN | S · 1.0.92 · [Bound and picked histories on both Hosts](evidence/rex-daily/results.json) |
| Grok Build – Send multiline text and read one reply | N NOT-RUN (macOS); N PASS (Debian, actual Grok clients) | N PASS | N PASS | T NOT-RUN | S · 1.0.92 · [Herdr Debian and both role counts](evidence/rex-daily/linux-herdr-grok-host.json) · [Rex](rex-chat-parity.md) |
| Grok Build – Answer initial directory trust | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Answer a matched tool approval | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Answer a program question | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Send a staged attachment in native Chat | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Stop only the current foreground turn | N NOT-RUN | N PASS (early stale Stop refused; visible turn canceled) | N PASS (visible turn canceled; peer untouched) | T NOT-RUN | S · 1.0.92 · [macOS provider and official transcript](evidence/rex-daily/mac-grok-stop.json) · [Debian](evidence/rex-daily/linux-grok-stop.json) |
| Grok Build – Inspect individual background work and later results | R NOT-RUN | R NOT-RUN | R NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |
| Grok Build – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | N PASS | N PASS | T NOT-RUN | S · 1.0.92 · [Bound and picked histories on both Hosts](evidence/rex-daily/results.json) |
| Grok Build – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | N NOT-RUN | N NOT-RUN | T NOT-RUN | S · 1.0.92 · [Chat](rex-chat-parity.md) |

## OpenCode 2.0.32

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| OpenCode – Bind the correct active conversation | N NOT-RUN | R PASS (explicit selection); U NOT-RUN (active writer) | R PASS (explicit selection); U NOT-RUN (active writer) | T NOT-RUN | S · 2.0.32 · [OpenCode selection through SSH](evidence/rex-daily/results.json) |
| OpenCode – Read the identified history | R NOT-RUN | R PASS (A and B selected and independently read) | R PASS (A and B selected and independently read) | T NOT-RUN | S · 2.0.32 · [OpenCode selection through SSH](evidence/rex-daily/results.json) |
| OpenCode – Send multiline text and read one reply | N NOT-RUN | T PASS (one targeted terminal send; A 1/1, B 0/0) | T PASS (one terminal send; A 1/1, B 0/0) | T NOT-RUN | S · 2.0.32 · [macOS database](evidence/rex-daily/mac-opencode.json) · [Debian database](evidence/rex-daily/linux-opencode.json) |
| OpenCode – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Answer a matched tool approval | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Answer a program question | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Send a staged attachment in native Chat | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Stop only the current foreground turn | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Inspect individual background work and later results | R NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 2.0.32 · [Chat](rex-chat-parity.md) |
| OpenCode – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | R NOT-RUN (explicit history selection) | R NOT-RUN (explicit history selection) | T NOT-RUN | S · 2.0.32 · [OpenCode selection through SSH](evidence/rex-daily/results.json) |

## Antigravity CLI 1.5.18

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Antigravity CLI – Bind the correct active conversation | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Read the identified history | R NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Send multiline text and read one reply | N NOT-RUN | T NOT-RUN | T PASS (first phone send created A; A 1/1, B unchanged) | T NOT-RUN | S · 1.5.18 · [Fresh terminal without a conversation](evidence/rex-daily/agy-first-unbound-linux-c.json) · [Phone message, official transcript and locks](evidence/rex-daily/agy-phone-after-linux-c.json) |
| Antigravity CLI – Answer initial directory trust | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Answer a matched tool approval | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Answer a program question | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Send a staged attachment in native Chat | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Stop only the current foreground turn | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Inspect individual background work and later results | R NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 1.5.18 · [Chat](rex-chat-parity.md) |
| Antigravity CLI – Open the sign-in screen on the selected Agent terminal | T NOT-RUN | T PASS (official sign-in entry) | T PASS (official sign-in and terms completed) | T NOT-RUN | S · [Terminal observations by program](rex-chat-parity.md) |

## Amp 0.0.1795737653-g84af98

| Scenario / harness | Herdr TUI baseline (macOS / Linux) | Rex macOS | Rex Linux | Rex native Windows | Candidate, version and evidence |
| --- | --- | --- | --- | --- | --- |
| Amp – Bind the correct active conversation | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Read the identified history | R NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Send multiline text and read one reply | N NOT-RUN | T NOT-RUN | T PASS (signed-in, one multiline send from iPhone; A 1/1, B 0/0) | T NOT-RUN | S · [Amp's official thread export](evidence/rex-daily/linux-amp-signed-host.json) · [iPhone action](evidence/rex-daily/linux-amp-terminal-ui.json) |
| Amp – Answer initial directory trust | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Answer a matched tool approval | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Answer a program question | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Confirm a plan or send feedback | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Send a staged attachment in native Chat | T NOT-RUN (Amp Chat hides the native file picker) | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · The Agent keyboard offers file staging in Terminal. [Amp surface and settings](rex-chat-parity.md) |
| Amp – Stop only the current foreground turn | T NOT-RUN (Amp Chat has no native Stop) | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · [Native Stop planner in the Chat surface](../../Sources/Heeler/Console/AgentChatSurfaceView.swift) |
| Amp – Inspect individual background work and later results | T NOT-RUN (the plugin pages messages and tool results) | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · [Amp transcript reduction](../../Sources/Heeler/Chat/Amp/AmpTranscriptReducer.swift) |
| Amp – Stop a selected background job | T NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Refuse stale input after a desktop session switch and recover the draft | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Reopen the same conversation after detaching or reconnecting | N NOT-RUN | T NOT-RUN | T NOT-RUN | T NOT-RUN | S · 0.0.1795737653-g84af98 · [Chat](rex-chat-parity.md) |
| Amp – Open the sign-in screen on the selected Agent terminal | T NOT-RUN | T PASS (official sign-in entry) | T PASS (vendor sign-in completed, debian CLI authenticated) | T NOT-RUN | S · [Terminal observations by program](rex-chat-parity.md) |

### Interpreting the open rows

A Rex-only Host has no persistent Heeler Usage or remote notification producer. An active-app banner uses Rex Program Status, the local preference and the verified current foreground. Background APNs, Live Activities and Usage widgets require separate registration and delivery. Native Windows still uses the named-pipe SSH branch and keeps its previously supported Claude Code capability. Its historical component checks are linked in the Rex guide. This run had no physical device with an available developer tunnel. [Host integrations](rex-host-services-parity.md) · [Native Windows](../guides/rex.md#known-limits)

The object probes found no conditional close on a foreground epoch at the negotiated revisions. Rex ignored a proposed expected-foreground field and closed the replacement program. Cross-session window transfer needs revision 22, and a move within a session can select an unintended desktop window. Those user actions remain gated. An explicit shell exit in the user's open terminal is recorded separately. [Protocol receipts and requested upstream changes](rex-object-operations.md#foreground-races-and-revision-gates)

For OpenCode 2.0.32 the two clients in one directory shared a database. Choosing a recorded session identifies its history. A native Send, Stop or answer would need an authoritative association between the current foreground and its active OpenCode session. Amp on Debian completed sign-in, returned two distinct official thread IDs and received the iPhone's multiline Terminal message in A. Antigravity CLI on Debian completed the official account flow, and the phone sent its first terminal message to A. Its new write lock and official reply were distinct from B. Sign-in and access to a terminal establish different facts from verified thread identity or an actionable request. [Program-specific findings](rex-chat-parity.md)

A macOS forwarding refusal exposed a path-spelling difference in the first SSH run. The private daemon listened on a /tmp pathname while the SSH login exposed the same inode under /private/tmp. The real connection worked. On refusal the lsof-based diagnostic called it stopped. A fresh pair of private listeners used the same pathname that the Host reported for discovery and forwarding. All four SSH tests passed there. The first failing result is retained.

For writable Chat, Heeler serializes its own writes per block. It rereads the active foreground, conversation and call or turn before the corresponding input. The tested interleavings include a desktop answer, a held button, a second similar request and a lost reply. Rex revision 19 has no conditional keypress against a prompt or foreground epoch. A second desktop writer could still act between the last read and the server applying the key. A server-side compare-and-apply request would close that interval.

The Linux Claude test initially required the macOS-rendered assistant bullet. It failed despite the independently recorded Debian reply. The amended test driver requires one entire marker line with a verified bullet, an idle or done foreground, and one matching official reply from the newly bound conversation. Its application runtime has the same SHA-256 as S. Both results and the test-only differences are retained. [Driver fingerprints](evidence/rex-daily/linux-claude-driver.json)

The Linux Codex run selected **Use current Git worktree** after desktop `/new`. The original test waited for an empty thread while Codex was waiting for this choice. The supplementary driver recognizes the vendor's full two-option prompt and makes one desktop selection. The original and amended XCTest executables both ran the same frozen app. The independent readback covers the old thread, the newly selected thread, and the unchanged peer. [Test hashes](evidence/rex-daily/linux-codex-driver.json) · [Official rollouts](evidence/rex-daily/linux-codex.json)

For Amp, two signed-in Debian clients published distinct per-process records and mode-0600 plugin sockets. The plugin's binding and paged history matched their independent official thread exports. The iPhone on S used the selected Terminal for its marked send. Those observations establish the host plugin protocol separately from the native app capability at S. [iPhone prompt and thread evidence](evidence/rex-daily/linux-amp-signed-host.json)


On the dedicated macOS SSH login and the separate Debian container, the first project suite ran all four methods. The app successfully created a Workspace and Worktree, applied literal arguments and the account directory, opened Files, Skills, Git patches and a real loopback web page. In both suites the foreground became visible before the test could decode the recorder's atomically published per-PID receipt. The independent file appeared with the intended directory. A fresh macOS retry of the isolated focused-split method passed. The later test checks for the published file before opening its JSON. The unchanged app passed all four project cases on each Rex-only Host with this test driver. The original red results are retained. [Focused Debian receipt](evidence/rex-daily/linux-focused-receipt.json) · [Live suite](../../Tests/HeelerLiveTests/RexProjectLiveTests.swift)

In both Rex-only environments the real Pi 1.5.2 foregrounds shared a directory and retained separate transcripts. One message and its answer appeared only on A. After the desktop changed threads, the new A received the subsequent unique marker. The old draft stayed with its original conversation, and peer B kept its entire file hash. The test also held both desktop grid owners while Chat operated and released them on exit. [macOS before and after](evidence/rex-daily/mac-pure-pi.json) · [Debian before and after](evidence/rex-daily/linux-pure-pi.json)
