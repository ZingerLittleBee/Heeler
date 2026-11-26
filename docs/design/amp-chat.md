# Implementation plan for Amp Chat

Proposed for Heeler at `16d4715df`, 2026-11-26.

The POSIX Herdr TUI implementation is recorded in
[ADR 0066](../adr/0066-amp-chat-follows-the-active-thread-in-its-terminal.md).
The installation flow, transcript and Composer were exercised on an iPhone
simulator over SSH to macOS, Herdr TUI 0.9.5 and Amp 0.0.1795608053-gcec25c.
Other Server Kinds remain future work. The plan below describes the starting point.

An Amp Agent should open the same Chat timeline and Composer as other Agents.
Chat should follow the thread visible in that terminal, show its history and
tool activity, and send a text reply to that thread. The first target is an
interactive Amp CLI running on the SSH Host on macOS or Linux. Approval
dialogs, attachments and Amp commands can initially be handled in Terminal.
Orbs, remote runners and native Windows need separate verification.

## What the interfaces support

- Amp exposes the focused thread through `amp.activeThread`, including a null
  selection. A plugin can read structured messages by thread ID, page through
  the full history and submit a message to a specific thread. A CLI can host
  several busy threads at once, so activity alone cannot identify the one on
  screen. [Amp plugin API](https://ampcode.com/docs/plugin-api) and
  [plugin lifecycle](https://ampcode.com/docs/customize/plugins).
- Heeler recognizes Amp as an Agent. Its Chat program list has no Amp adapter.
  Herdr TUI currently reports Amp's state only. Amp therefore needs its own
  source of thread identity on this Server Kind too.
  [ChatProgram](../../Sources/Heeler/Chat/ChatTranscript.swift) and
  [Herdr agent support](https://herdr.dev/tui/docs/agents/).
- On macOS, two isolated `amp plugins exec` processes using CLI
  `0.0.1795608053-gcec25c` each answered a request on a separate mode-0600
  Unix socket and returned evidence from its own synthetic event. In both
  runs the plugin process was a child of the CLI. Interactive thread
  selection, reading a real thread, real Send and SSH forwarding still need
  the checks below.

## Implementation order

1. **Prove the binding in a real TUI.** Start two signed-in Amp terminals in
   one directory on a scratch Herdr TUI Server. Record how the plugin process
   relates to the foreground Amp process and what `activeThread` reports at
   startup, on the first prompt, on an idle thread switch, on resume and when
   the other thread finishes a turn. Confirm that the focused thread's
   `messages({ full: true })` and `appendUserMessage` work from a plugin
   request while Amp is idle. Capture sanitized records and screens. These
   observations determine the process match, the empty-thread behavior and
   the first supported CLI version.

2. **Bundle the Amp plugin and install it from Chat.** Ship one versioned
   plugin file in the app. Offer **Install Amp Plugin** when it is missing.
   Resolve the running CLI's system plugin directory from its
   `XDG_CONFIG_HOME` or `~/.config/amp/plugins/`, show the destination and
   install on the user's request. Replace a Heeler-owned copy atomically and
   preserve a conflicting user file. After **plugins: reload** or a CLI
   restart, verify the version through the running plugin. One install
   serves terminals using that Host account and configuration.
   [Amp plugin locations](https://ampcode.com/docs/customize/plugins) and
   [existing extension install flow](../../Sources/Heeler/Console/HerdrCoreWindowsExtensions.swift).

3. **Connect the selected Agent to its plugin.** The proposed plugin serves
   three operations over a private Unix socket while the local Amp TUI is
   running. They return the current binding, read a page, and submit text.
   Discover the socket through a small record scoped to the foreground Amp
   PID and process start. Prove the process belongs to the selected Pane or
   Terminal before using the record. Give each plugin load a new instance ID
   and each focus change a revision. The plugin accepts reads and sends only
   for that binding. Resolve the socket inside a private directory owned by
   the SSH user and make bounded requests over the existing SSH connection.
   Amp reads the messages with its own signed-in account. Surface forwarding
   refusal or an incompatible plugin in Chat.
   [Host evidence binder](../../Sources/Heeler/Chat/Source/HerdrCoreSessionBinder.swift)
   and [SSH socket exchange](../../Packages/HeelerSSH/Sources/HeelerSSH/SSHConnection.swift).

4. **Feed the existing timeline.** Add `.amp` and an Amp source through
   `ChatTranscriptAdapter.makeRecordSource`. Supply plugin evidence for Amp
   in `ConsoleStore.chatStore`, including on Herdr TUI. Recheck focus while
   Chat is visible and idle. A changed binding discards late responses for
   the previous selection. A null binding shows an empty state and points to
   Terminal to start or select a thread. Read the latest page first and older
   pages on demand with `full: true` and at most 20 messages per call. Anchor
   overlapping pages by message ID, which can be a number or a string. Merge
   updated content by that ID and pair tool calls with results by tool-use ID.
   Bound tool output and use the existing on-device cache. Deliver turn and
   tool updates as Amp exposes them. Measure partial text updates in the lab
   before promising streaming.
   [Chat source](../../Sources/Heeler/Chat/Source/ChatTranscriptSource.swift)
   and [engine entry](../../Sources/Heeler/Chat/Conversation/ChatConversationEngine.swift).

5. **Route Amp Chat Send by thread ID.** Keep the Composer's draft,
   readiness checks and delivery states. Capture the plugin instance, focus
   revision and thread ID the user sees. The plugin rechecks them immediately
   before calling `amp.threads.get(expectedID).appendUserMessage(...)`.
   A changed selection, blocked Agent or unrecognized input screen leaves
   the draft available. Identify the request by the Composer message ID and
   accept it once per plugin instance. If the response is lost after dispatch,
   show an unknown outcome and reconcile with the transcript without replaying
   the submit. This Amp-specific route needs an ADR because Chat currently
   sends through the Server Kind's terminal input.
   [Composer delivery](../../Sources/Heeler/Console/AgentComposerStore.swift)
   and [existing Chat contract](../adr/0024-native-chat-from-agent-transcripts.md).

6. **Enable by Server Kind and OS.** Take Herdr TUI through the complete
   install, read and send flow first. Then wire herdr-core and tmux to their
   foreground process evidence and validate each separately. They currently
   share program lists, so enabling one must not implicitly advertise an
   unverified combination. Rex additionally needs an explicit amendment for
   installing the Amp plugin and sending through it. Enable Rex after its
   own end-to-end check. Apply availability to the detail, list and cache
   prefetch. Update the domain docs, navigation, changelog and committed
   Xcode project with the implementation.
   [Host capabilities](../../Sources/Heeler/Console/HostCapabilities.swift),
   [core Composer](../adr/0035-herdr-core-composer-sends-through-the-attach.md),
   [tmux](../adr/0045-tmux-hosts-poll-inventory-and-attach-through-control-mode.md)
   and [Rex Chat](../adr/0056-rex-agents-open-the-agent-detail-with-chat.md).

## Acceptance

| Scenario | Observable result |
| --- | --- |
| Two Amp terminals in one directory, both producing output | Each Agent shows its own selected thread. Background events do not move either timeline. |
| Switch A to B while idle, while loading history and just before Send | Chat follows B and discards outstanding A reads. A pending submit for A is refused if the switch happens before acceptance. A submit already accepted for A only appears in A. |
| Resume a compacted thread with more than 20 messages and repeated prompts | Paging reaches the earlier turns with no missing or duplicate rows. Repeated prompts remain distinct, including while new messages arrive. |
| Fresh terminal, plugin missing, plugin reloaded or Agent exited | Chat distinguishes installation, waiting for a thread and a stale binding. Old cached content cannot authorize a send. |
| Approval dialog, terminal draft or disconnect during Send | The dialog and draft survive. Reconnecting reveals any delivered message without sending it again. |

Run the focused app tests with `make test-app TEST_SELECTOR='HeelerTests/<suite>'`
and record executed counts. Run the matrix through the iOS Simulator over SSH
against real Amp terminals for each Server Kind and OS being enabled. Record
the Heeler commit, Amp version, Server version and observed thread IDs with
the fixture and lab results. The local plugin probe covers socket communication
only.
