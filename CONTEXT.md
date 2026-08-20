# Heeler

A native iOS agent console for herdr. One context: the app. Terms owned by herdr keep herdr's meaning; this glossary pins how we use them client-side.

## Language

**Host**:
A remote machine reachable over SSH that runs a herdr server. The unit a user adds, names, and authenticates against.
_Avoid_: server, machine, connection

**Jump Host**:
An SSH endpoint that forwards a Host connection when the Host is not directly
reachable from the device. The Host's address and port are resolved from the
Jump Host, normally through a loopback-only reverse tunnel. The app authenticates
and verifies host keys independently at both hops.
_Avoid_: bastion, proxy server

**Device Key**:
The device's SSH identity: an Ed25519 keypair generated on this device. The private key never leaves the Keychain; the public half is what a Host authorizes.
_Avoid_: app key, client key

**Pairing**:
The full new-device ceremony: scan a Pairing Code, connect with its Bootstrap Key, complete Enrollment, then reconnect with the Device Key. Success produces a working Host, persisted only at that point.
_Avoid_: scan to connect, binding

**Pairing Code**:
The versioned pairing payload (candidate addresses, host key fingerprint, Bootstrap Key, expiry) produced by the pairing plugin. The QR image is just its rendering.
_Avoid_: QR code, invite

**Bootstrap Key**:
A single-use, TTL-bound Ed25519 keypair carried inside a Pairing Code. Its authorized_keys line is restricted to a forced command that can only perform Enrollment; it is destroyed on success or expiry.
_Avoid_: temp key, one-time password

**Enrollment**:
The server-side step of Pairing: the forced command appends the Device Key's public key to authorized_keys. Distinct from Pairing as a whole — failure copy must say which step failed.
_Avoid_: install key, authorization

**Agent**:
A coding agent process (claude, codex, ...) running inside a herdr pane, as reported by herdr's detection. The primary object of the app.
_Avoid_: bot, task, session

**Staged Image**:
A user-selected image that exists on a Host at a remote path, whether or not the Agent has accepted it into a prompt.
_Avoid_: attachment, uploaded image

**Staged File**:
A user-selected file that exists on a Host at a remote path, whether or not the Agent has used it from a prompt.
_Avoid_: attachment, uploaded file

**Image Attachment**:
A Staged Image that the Agent has accepted into its current prompt as image input.
_Avoid_: staged image, image path

**Add**:
The Composer action that prepares one selected image or file, creates a Staged
Image or Staged File, and inserts its Host path into the local draft without
submitting it. The action does not assert that the Agent accepted an Image
Attachment or used a Staged File.
_Avoid_: attach image, send image, upload image

**Agent Status**:
herdr's detected state of an Agent: Idle, Working, Blocked, Done, or Unknown. Blocked means the agent is waiting for human input and drives sort order and (later) notifications.
_Avoid_: agent state, activity

**Pane**:
herdr's unit of terminal real estate that an Agent lives in. Used as an address (`pane_id`), never as a layout concept in this app.
_Avoid_: window, tile

**Worktree**:
A fresh git checkout of a workspace's repository, created by herdr as its own
workspace so a new Agent starts on a clean copy of the code. The branch
defaults to herdr's generated `worktree/<name>` off HEAD; removing the
Worktree deletes the checkout and closes its workspace, but the branch
survives.
_Avoid_: sandbox, branch copy, checkout folder

**Console**:
The native dashboard surface: the flat, status-sorted list of Agents across Hosts, plus the Agent detail screen.
_Avoid_: dashboard, home

**Composer**:
The local input control below the Agent's live terminal: a native draft field
that composes a message entirely on device and delivers it in one piece. Its
tools keyboard sends explicit terminal controls directly to the Agent without
editing the draft, while its Snippet and Skill tools insert into that draft. A
draft insertion edits the draft and nothing more; delivery is a separate,
explicit act.
Delivered means the Host accepted the text into the pane — whether the Agent
queues or acts on it is the Agent's business, and the Composer never claims
otherwise.
_Avoid_: reply bar, compose bar (the shelved predecessors), input box, message box

**Attach**:
The realtime PTY stream behind Agent detail. libghostty renders the complete
TUI, owns local scrollback, and reports its grid size so the remote PTY resizes
with the view. The surface is display-only: authored input belongs to Composer
and reaches the Agent through one `agent.prompt` request. Only Composer's
explicit tools-keyboard controls send terminal control sequences.
_Avoid_: takeover (that's herdr's flag, not our surface), connect

**Attach Link**:
An ordinary web URL observed in the terminal during one Agent detail session. It remains
available after scrolling or reconnecting, but is forgotten when the user
leaves the detail; a later session discovers whatever its terminal shows anew.
_Avoid_: recent link, visible link, link history

**Terminal Keyboard**:
The two keyboard modes below Composer, swapped in place at one shared measured
height. The standard iOS keyboard edits the draft with composition,
autocorrection, dictation, and language switching. The tools keyboard replaces
it with a tabbed pad: Agent controls send key sequences directly to the pane,
while Skills, Snippets, and terminal appearance edit the draft or the terminal
and never touch the pane.
_Avoid_: desktop keyboard, reply keyboard, Keys mode (the direct-input predecessor)

**Snippet**:
A phrase the user writes once and reuses, kept in one global set independent of
any Host or Agent. Tapping one inserts its text into the Composer draft and
nothing more; the user still delivers it. A Snippet may carry a Title: a short
name the user gives it, shown above its text wherever Snippets are listed.
_Avoid_: macro, template, shortcut, quick reply, tip

**Project Files**:
The browsable directory tree and code editor for one Agent's Project Root,
reached from the Agent's More menu. Docked beside the terminal on iPad,
a sheet on iPhone. Listings, reads, and saves go over the app's own SFTP
(ADR 0015); herdr is not involved.
_Avoid_: file manager, finder, explorer, IDE

**Project Root**:
The directory an Agent's Project Files are rooted at: the workspace's
worktree checkout when it has one, else the Agent's launch cwd — the same
root the Skills probe uses, deliberately not the live foreground cwd.
_Avoid_: working directory, current directory

**Host Files**:
The Host-level Files surface: the remote machine browsed from its home
directory, opened from the Console sidebar's Files section. On iPad the
detail column splits into tree and editor; Project Files remains the
Agent-scoped view of the same machinery.
_Avoid_: remote browser, SFTP client

**Agent Notification**:
A notification telling the user an Agent crossed a notify-worthy status boundary (Blocked, Done): an APNs push while backgrounded or killed, an in-app banner off the live event stream while foregrounded. Deep-links to the Agent's detail surface.
_Avoid_: alert, push message, task notification

**Push Relay**:
The developer-hosted, stateless forwarder that holds the APNs credentials and relays encrypted notification payloads from Hosts to Apple. It sees device tokens and ciphertext, never content.
_Avoid_: server, backend, push service

**Notification Key**:
The symmetric key generated on device and stored on a Host during Notification Registration; encrypts Agent Notification content end to end so the Push Relay cannot read it.
_Avoid_: shared secret, push key

**Notification Registration**:
The act of writing the device's push token and Notification Key to a Host over SSH. Per host, repeatable, and independent of Pairing; removing it disables Agent Notifications from that Host.
_Avoid_: subscribe, enable push

**Transport**:
The app-side abstraction that executes herdr API requests and delivers event streams over SSH. UI code talks to Transport, never to SSH primitives.
_Avoid_: client, bridge, tunnel

**Connection Guidance**:
The text a `TransportError` carries for the user, `connectionGuidance`, as
against the shorter phrase the Console composes for the same error in
`summary(for:)`. Only two statuses carry a `TransportError` at all,
`.reconnecting` and `.failed`, and they partition the error set: the session
emits `.failed` only where `isRetryable` is false and `.reconnecting` only
where it is true. On `.failed` the text names an action the user can take in
10 of the 12 cases `isRetryable` rejects outright; on `.reconnecting` it does
so in none of the 5 it accepts, restating what happened and appending the
transport's raw detail in three of them (`jumpHostFailed` prefixes and
inherits whichever it wraps). So what the guidance adds over the Console's
phrase during a reconnect is raw detail or nothing, never an instruction, and
the name promises more than the strings deliver; #163 owns whether the strings
gain actions or the term is renamed.
Four surfaces turn those two statuses into text. The Console list shows the
short phrase on `.reconnecting` and the guidance on `.failed`. The Agent
detail screen (`MissingAgentPresentation`) shows a fixed "nothing to do"
message on `.reconnecting` and the guidance on `.failed`. The Host detail
screen (`HostOnboardingView.connectionErrorMessage`) shows the guidance on
both, and is the only surface that shows it while a retry is in flight. The
Hosts sheet rows (`HostConnectionPresentation`) show a status chip,
"Reconnecting…" or "Unavailable", and never the guidance at all: a chip is not
guidance, so those rows sit outside this term.
Two exceptions the description keeps rather than tidies away. The Host detail
footer is gated on no manual Reconnect being in flight, so pressing Reconnect
suppresses the guidance entirely for the length of the retry call plus 1.2 s —
on `.failed` as much as on `.reconnecting` (#160). And that screen is reached
four ways: a Host row, the add form, a finished Pairing scan, and a deep link,
which is what the Console's own issue buttons use to push the user onto it.
Only the two surfaces with a presentation type of their own are tested; the
Console list and the Host detail footer live inside `View` bodies and have no
coverage.
_Avoid_: error message, connection error, retry hint

**Background Grace Period**:
The window after backgrounding during which the app keeps running under an iOS background-execution assertion and holds its Host connections, so a short trip out of the app costs nothing on return. Only when it elapses does the app suspend and tear the connections down. Bounded by what iOS grants (tens of seconds); staying reachable for longer is what Agent Notifications are for.
_Avoid_: background mode, keep alive (that's the events session's ping)
