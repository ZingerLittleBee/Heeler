# Rex and Herdr TUI on a Linux Host

On November 27, 2026, a disposable Debian 12.15 arm64 Host ran Rex 0.1.0-preview.25 (`b070aae645f5`) and Herdr TUI 0.9.5. OpenSSH 9.2 forwarded a Unix socket through loopback SSH from the Mac. The Host ran Linux `7.2.12-orbstack-00394-gbecdd6130068`, Bash and Git 2.39.5. The Rex archive's SHA-256 matched the publisher's `37908dc3e79386b05fcd2e26d1bcf3c28f34536fc816eb8126a9b9c65266f630`. The container had a fresh account and host key and no host mounts. [Rex Linux distribution](https://www.superlogical.com/rex/docs/linux/installation) · [Rex preview release manifest](https://blob.superlogical.com/api/releases/rex/preview) · [Herdr 0.9.5 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.5)

## Server behavior

| Operation | Observed over SSH |
| --- | --- |
| Negotiate and list | `server.version` returned `linux_arm64` and server API 24. A client offering 12 received 12. A client offering 19 with a floor of 12 received 19. At both revisions `session.attach_all` and `session.list` returned the fixture session. |
| Launch a background window | At both revisions, `session.new_window` kept the original active window. The child reported the requested directory containing a space, four distinct arguments containing quotes, Unicode, a newline and literal shell metacharacters, and the original environment value. After `session.disown_block`, both blocks reported no owner. |
| Launch with a directory that disappeared | At revision 19, `session.new_window` returned window and block IDs. The launch command's directory check failed. The terminal's `process` reply contained `last_exit.exit_code = 2` and the account's home. The requested executable never wrote its marker there. |
| Rename a Workspace | At both revisions, `session.set_label` changed the Unicode label visible in `session.view` and preserved the session ID. After destroying that session, another rename of the old ID returned `session_not_found`. |
| Identify a launched process | A local executable named `claude` recorded its arguments, directory, environment and PID. Rex's foreground PID, its idle Program Status owner and the executable in Linux `/proc` agreed. This fixture measures New Agent delivery. The real coding agents exercised below were Pi, Oh My Pi and Grok Build. |

The wire probes opened a separate session per revision and removed it after checking it. Their JSON payloads used the same terminal flavor, commands and focus setting as [RexNewTerminal](../../Sources/Heeler/Transport/Rex/RexHostSession.swift).

A second Debian container started with an empty private home and a different SSH host key. Its account had only the Rex executable. Neither `REX_RUNTIME_DIR` nor `XDG_RUNTIME_DIR` was set. Rex listened on its default `$HOME/.local/state/rex/run/server.sock`, and listed the one shell Workspace. The account had no herdr, herdr-core or tmux executable on its path and no corresponding socket in `/proc/net/unix`. The raw readback is in `build/heeler-lab-evidence/linux-raw/rex-only-detection.json`.

## Real Pi on the two servers

Pi 1.5.2 ran with Node 25.8.1 in an isolated project. A provider listening only inside the container returned the test marker verbatim, which let the observer count user and assistant records without using a provider account. Each backend ran the published CLI interactively. [Pi distribution](https://www.npmjs.com/package/@earendil-works/pi-coding-agent/v/1.5.2) · [Pi-compatible model configuration](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/models.md)

| Scenario | Linux result |
| --- | --- |
| Herdr TUI reference | Herdr's Pi integration and `agent.start` launched Pi in the requested project. `agent.get` returned an `agent_session` of kind `path` from `herdr:pi`. The named JSONL contained two user and assistant pairs. After `/new` in the terminal, Herdr published a different path. A third prompt and reply appeared there once and the old file kept the same bytes. |
| Rex with the extension at `10148154331e5496afaef9b5b450d514fd1d7d8e` | The foreground Pi completed its first turn. Its environment had `REX_BLOCK` and lacked `REX_SESSION` and `TMUX`. The transcript existed and Pi listed the loaded extension, but no `heeler-session/<pid>.json` appeared. |
| Rex after updating the extension | Reloading the candidate extension inside that same running Pi produced a report with its original session ID, transcript path, PID and Linux process start. Two further Pi processes in the same project and account directory produced separate reports. Each matched its own `/proc/<pid>/stat` start and independently seeded transcript. |
| Desktop session switch and exit | After `/new`, the first Pi kept the same PID and start and published a new session ID and path. Only the new transcript received the subsequent user and assistant marker. `/quit` removed the PID and its report. Both transcripts remained on disk. |
| Interrupt a working turn | A separate real Pi reported `working` with its foreground PID while a loopback provider held its first request. One Escape over the Rex control path made Pi record `stopReason: aborted`. The same PID completed the next prompt with one matching user and assistant pair and reported `done`. |

A separate Pi 1.5.2 reported two successive native `blocked` records, both owned by the same foreground PID. A lab extension opened two real `context.ui.confirm` dialogs, one on top of the other. Each permission record carried its dialog's distinct title and Rex update timestamp. Closing both returned Pi to idle. A separate prompt held its model call for five seconds and took Pi from working to done. The Host receipts are in `build/heeler-lab-evidence/linux-raw/notification-probe.txt`.

The starting extension had SHA-256 `ab8792a91a61519da20db8c7683a88925d45da6f60d781cecb60b4fe3cbd61e2`. The standalone switch and interruption checks used `030a43318c8704341d25cf78563378ad7200184b0f5ce6ebab457445de4feccf`. Both same-directory peers then reloaded the extension from `7fd45e10b32d70061fc61cf4ba7d20fdcaaafa3e`, SHA-256 `2a8899e73ba2d332dd3a51cc34125804966749834be7bd662ca213a34f36d1c3`. Both rewrote the same verified PID, start, session and path. These observations come from the CLI, real Rex control frames and independently read Host files. [Extension](../../plugin/helper/extensions/heeler-session.js) · [Pi process and file binding](../../Sources/Heeler/Chat/Source/HerdrCoreSessionBinder+Pi.swift) · [Earlier Droid runs](droid-chat-validation.md) · [Earlier Devin runs](devin-chat-validation.md)

## Rex Chat through the iOS Simulator

Oh My Pi 18.12.3 also ran two independent native Linux clients in one project and account directory. The release binary's SHA-256 was `58f7c25e9b729b082192049ada07a31820c8b257325545a5fe232ff1679f1093`. PIDs 5342 and 5377 each reported their own Linux start tick and JSONL. The initial user and assistant pair in each file matched only the marker sent to that process. [Oh My Pi 18.12.3 release](https://github.com/can1357/oh-my-pi/releases/tag/v18.12.3)

The iPhone 17 Pro Simulator on iOS 27 ran `RexForegroundChatLiveTests` once for Pi and once for Oh My Pi against this Linux Host, over the app's SSH connection. Each result bundle contained one passed test and zero skips. Both clients bound to their own conversations. A multiline prompt reached only its chosen peer and received one matching reply. After the desktop client issued `/new`, a staged draft was refused and its marker appeared in none of the three files. Both terminals kept the desktop client's size and ownership. The two local result bundles are `build/heeler-lab-evidence/chat/linux-pi-v2.xcresult` and `build/heeler-lab-evidence/chat/linux-omp-v2.xcresult`. These runs used the extension SHA identified above and a working tree with application changes. [Live test](../../Tests/HeelerLiveTests/RexForegroundChatLiveTests.swift)

Two native Grok Build 1.0.92 clients (`b06756fd6256`, official Linux arm64 package) used one `GROK_HOME`, one project and one loopback Chat Completions endpoint. Each row in `active_sessions.json` matched its Rex foreground PID, directory and Linux `/proc/<pid>/stat` start tick. Both UUIDs had their own nonempty `updates.jsonl`; each sibling `chat_history.jsonl` contained its own initial marker once as user and once as assistant. [Grok Build distribution](https://www.npmjs.com/package/@xai-official/grok/v/1.0.92) · [Model configuration](https://docs.x.ai/build/settings)

## SSH interruption and server replacement

A separate Linux fixture had one Unix socket, a private SSH proxy and two sessions with fixed labels. Its target initially ran a stand-in executable named `claude`, started from an ordinary shell. Its peer ran Bash. An independent SSH client changed the server state and read each process and screen. The following observations came from native OpenSSH, the Rex CLI and a WebSocket client negotiating revision 19.

| Transition | Linux observation |
| --- | --- |
| Cut an established SSH connection | The proxy reset one TCP connection. The open WebSocket and its SSH process ended. A new SSH tunnel reached the same Rex instance with the same sessions. A client that had called only `server.status` received a new client ID with its reconnect token. A second client that subscribed with `session.attach_all` before the reset resumed with the same client ID (`resumed: true`) two seconds after the reset. |
| Restart from the same state directory | Rex returned a new instance ID, preserved the file-host ID and restored both original session and block IDs. Both foregrounds had new PIDs and ran Bash. |
| Replace the server at the same socket | A fresh state directory contained only the previous fixture's `host-id` and no snapshots. The new instance reported the same file host and labels, with two new session and block IDs. Both independent screen reads found ordinary shells. |

The opt-in Simulator test passed once in 11.034 seconds in the working-tree run `build/heeler-lab-evidence/services-linux-current.xcresult`. Heeler reconnected to the original instance after the proxy cut one live SSH connection. After restore it kept the Pin and refused a paste from the departed Agent. At the replacement it pruned the Pin and refused that paste against the old server identity. An independent SSH observer found no marker in the target or peer after either attempt. The host receipts are in `build/heeler-lab-evidence/linux-raw/recovery-app.json`. The fixture creates a fresh directory and stops only its recorded Rex instance. [Live test](../../Tests/HeelerLiveTests/RexRecoveryLiveTests.swift) · [Fixture controller](../../scripts/fixtures/rex-recovery.py)

To run it, give `python3 scripts/fixtures/rex-recovery.py` a private SSH `--lab` JSON with `port`, `user`, `seed` and `fingerprint`, a pinned `--ssh-config`, a disposable loopback `--target heeler-lab-…` and a new `--output` directory. Set `TEST_RUNNER_HEELER_REX_RECOVERY_LAB` to the emitted `fixture.json` path and select `HeelerLiveTests/RexRecoveryLiveTests` with `make test-app SCHEME=HeelerLiveTests`. The controller records observations in `evidence.json` and tears down after the final screen check.

## Reproducing the Pi fixture

1. Start a personal Rex server in a fresh Linux SSH account. Give two interactive Pi clients the same disposable project and `PI_CODING_AGENT_DIR`. Place the candidate extension at `extensions/heeler-session.js` in that agent directory.
2. Send a different initial marker to each Pi. Find each JSONL by its unique user and assistant pair. Read each terminal's foreground PID, compare its process start and report, and record the raw session and block IDs from Rex.
3. Set `TEST_RUNNER_HEELER_REX_FOREGROUND_CHAT_LAB` to the path of a private fixture on the Simulator machine. Its fields are `port`, `user`, `seed`, `fingerprint`, `rexSocket`, `rexSession`, `rexBlock`, `program`, `directory`, `firstFile`, `peerSession`, `peerBlock` and `peerFile`. Run `make test-app SCHEME=HeelerLiveTests TEST_SELECTOR=HeelerLiveTests/RexForegroundChatLiveTests` on the selected Simulator. [Live test](../../Tests/HeelerLiveTests/RexForegroundChatLiveTests.swift) · [Test selection and result counts](testing.md)

The recovery fixture also runs on macOS. On the tested Mac, preview.25 restored the same block IDs into the account's fish login shell. The fresh test windows had explicitly started Bash. The independent observer compares the restored processes with the Host's configured login shell and checks that the old Agent's input appears on neither screen.
