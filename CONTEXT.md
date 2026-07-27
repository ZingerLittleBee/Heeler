# herdr-mobile

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

**Image Attachment**:
A Staged Image that the Agent has accepted into its current prompt as image input.
_Avoid_: staged image, image path

**Attach Image**:
The Attach action that prepares one selected image, creates a Staged Image, and offers its path to the current terminal. The label expresses user intent; it does not assert that the Agent accepted an Image Attachment.
_Avoid_: send image, upload image

**Agent Status**:
herdr's detected state of an Agent: Idle, Working, Blocked, Done, or Unknown. Blocked means the agent is waiting for human input and drives sort order and (later) notifications.
_Avoid_: agent state, activity

**Pane**:
herdr's unit of terminal real estate that an Agent lives in. Used as an address (`pane_id`), never as a layout concept in this app.
_Avoid_: window, tile

**Console**:
The native dashboard surface: the flat, status-sorted list of Agents across Hosts, plus the Agent detail screen.
_Avoid_: dashboard, home

**Attach**:
The Agent detail surface: full interactive terminal control of the pane through
the embedded terminal. The normal terminal buffer uses native local scrollback.
Alternate-screen TUIs map vertical touch drags and momentum to terminal wheel rows.
Only a tap near the input row opens the software keyboard, so a touch anywhere
else is never answered with a keyboard-driven viewport resize. In the normal
buffer the band is one row; on the alternate screen it stays caret-anchored but
grows to cover the TUI's whole input box, because agent TUIs park the caret
below the visible prompt. The tap that halts a flick is spent on the halt alone.
_Avoid_: takeover (that's herdr's flag, not our surface), connect

**Terminal Keyboard**:
The two input modes used within Attach. Text keeps the standard iOS input method
for composition, autocorrection, dictation, and language switching. The Keys mode
replaces it with a tabbed pad of terminal-side surfaces: control keys for
navigation and common control signals, Snippets, and terminal appearance.
Input from either mode goes directly to the Agent's pane.
_Avoid_: desktop keyboard, reply keyboard

**Snippet**:
A phrase the user writes once and reuses, kept in one global set independent of
any Host or Agent. Tapping one inserts its text into the Agent's pane and
nothing more; the user still submits it. A Snippet may carry a Title: a short
name the user gives it, shown above its text wherever Snippets are listed.
_Avoid_: macro, template, shortcut, quick reply, tip

**Terminal Paste**:
A user-invoked insertion of plain text from the iOS clipboard into Attach. Single-line text proceeds directly; potentially executable multiline or control content requires review.
_Avoid_: Control V, image paste

**Agent Notification**:
A notification telling the user an Agent crossed a notify-worthy status boundary (Blocked, Done): an APNs push while backgrounded or killed, an in-app banner off the live event stream while foregrounded. Deep-links to the Agent's Attach surface.
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

**Background Grace Period**:
The window after backgrounding during which the app keeps running under an iOS background-execution assertion and holds its Host connections, so a short trip out of the app costs nothing on return. Only when it elapses does the app suspend and tear the connections down. Bounded by what iOS grants (tens of seconds); staying reachable for longer is what Agent Notifications are for.
_Avoid_: background mode, keep alive (that's the events session's ping)
