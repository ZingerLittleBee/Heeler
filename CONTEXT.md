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
herdr's unit of terminal real estate. A Pane hosts either an Agent or an
ordinary shell — a workspace's root pane starts as a shell. Used as an address
(`pane_id`), never as a layout concept in this app.
_Avoid_: window, tile

**Workspace**:
herdr's unit that groups tabs and panes around one working directory. New
Agent can start in an existing Workspace, a new Worktree of one, or a new
Workspace opened at a remote directory. The id is an opaque string.
_Avoid_: project, folder, window

**Worktree**:
A fresh git checkout of a workspace's repository, created by herdr as its own
workspace so a new Agent starts on a clean copy of the code. The branch
defaults to herdr's generated `worktree/<name>` off HEAD; removing the
Worktree deletes the checkout and closes its workspace, but the branch
survives. Snapshot worktree metadata also describes the main checkout; only
`is_linked_worktree` makes a workspace eligible for linked-Worktree removal.
_Avoid_: sandbox, branch copy, checkout folder

**Console**:
The native dashboard surface: Agents across Hosts as either a flat status-sorted list or a by-Host grouped list with collapsible sections, plus the Agent detail screen.
_Avoid_: dashboard, home

**Pin**:
A user-chosen Console marker on an Agent's pane slot (`hostID` + `paneID`).
Pinned agents float to the top of the Console list and the Live Activity
by recency. Pins persist locally and are never pruned, so a pane id that
returns after a herdr restart stays pinned.
_Avoid_: favorite, star, bookmark

**Composer**:
The local input control below the Agent's live terminal: a native draft field
that composes a message entirely on device and delivers it in one piece. Its
tools keyboard sends explicit terminal controls directly to the Agent without
editing the draft, while its Snippet and Skill tools insert into that draft. A
draft insertion edits the draft and nothing more; delivery is a separate,
explicit act.
Authored delivery is one `agent.prompt` request, except when Agent Status is
Blocked: Send then inserts the draft into Attach without Enter, and the tools
keyboard submits or cancels. Delivered means the Host accepted the text into
the pane — whether the Agent queues or acts on it is the Agent's business,
and the Composer never claims otherwise.
Composer remains the default authored-input path on Agent detail. Direct Input
is an explicit, opt-in alternative that hides the Composer card without
clearing or submitting the draft.
_Avoid_: reply bar, compose bar (the shelved predecessors), input box, message box

**Attach**:
The realtime PTY stream behind Agent detail, Agent-specific. In Composer mode
it is display-only: libghostty renders the complete TUI, owns local scrollback,
and reports its grid size so the remote PTY resizes with the view, while
authored input belongs to Composer. Direct Input is the scoped exception that
lets the system keyboard type that same Attach PTY.
Delivery is one `agent.prompt` request, except when Agent Status is Blocked, in
which case Composer Send inserts the draft into Attach without Enter and the
tools keyboard submits or cancels. Only Composer's explicit tools-keyboard
controls (and Direct Input's shortcut row / system Return) send terminal
control sequences. The directly interactive surface on an ordinary shell is
the Shell Terminal, never unqualified "Attach".
_Avoid_: takeover (that's herdr's flag, not our surface), connect

**Attach Link**:
An ordinary web URL observed in the terminal during one Agent detail session. It remains
available after scrolling or reconnecting, but is forgotten when the user
leaves the detail; a later session discovers whatever its terminal shows anew.
_Avoid_: recent link, visible link, link history

**Shell Terminal**:
The full interactive terminal on an ordinary shell Pane, opened by Agent
detail's Open Terminal action. Heeler creates a fresh herdr tab in the Agent's
launch directory and attaches the returned terminal id through herdr's direct
terminal attach with takeover. libghostty renders it, and direct keyboard
input and PTY resize go straight to the remote terminal — no Composer, no
Agent semantics, no notification routing. It replaces Agent detail while open
so the Host's single terminal lifetime hands off cleanly; Back detaches and
leaves the remote tab alive for desktop handoff.
_Avoid_: Attach (that's the Agent-specific display surface), shell console,
terminal pane view

**Direct Input**:
The opt-in Agent-detail mode that hides the Composer card and routes the
system keyboard plus a compact app-owned shortcut row (Esc, Tab, Shift-Tab,
Enter) into the live Attach PTY. The draft stays in `AgentComposerStore`
untouched. Mode preference is app-wide, default off. Distinct from Shell
Terminal (ordinary shell, no Agent semantics) and from Terminal Keyboard (the
iOS/tools swap under Composer).
_Avoid_: Keys mode, terminal mode, raw input, Attach mode

**Terminal Keyboard**:
The two keyboard modes below Composer, swapped in place at one shared measured
height. The standard iOS keyboard edits the draft with composition,
autocorrection, dictation, and language switching. The tools keyboard replaces
it with a tabbed pad: Agent controls send key sequences directly to the pane,
while Skills, Snippets, and terminal appearance edit the draft or the terminal
and never touch the pane. Direct Input reuses the same measured footprint for
an optional tools dock, but its primary shortcuts persist in an app-content
row above the Agent switcher strip rather than replacing the system keyboard.
_Avoid_: desktop keyboard, reply keyboard, Keys mode (the direct-input predecessor)

**Snippet**:
A phrase the user writes once and reuses, kept in one global set independent of
any Host or Agent. Tapping one inserts its text into the Composer draft and
nothing more; the user still delivers it. A Snippet may carry a Title: a short
name the user gives it, shown above its text wherever Snippets are listed.
_Avoid_: macro, template, shortcut, quick reply, tip

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

**Host Connection Status**:
Where one Host's events session stands, as the user is entitled to see it. Five
connection conditions, plus one ownership terminal. Connecting, Reconnecting
and Connected say connection work is under way or done; Suspended and Failed
say none is. Ended is not a connection condition at all: it retires the events
session for good, and belongs to whoever owns that session.
Connecting means a new activation is establishing its first usable events path
— the SSH connection, the herdr ping, the events subscription — outside the
automatic retry loop. Every activation announces it, synchronously, before its
run begins: a first dial, a return from Suspended, and a Reconnect Request from
Connected, Reconnecting or Failed alike. Automatic iterations inside one
activation stay Reconnecting.
Reconnecting is automatic recovery after a retryable failure, and covers its
announced backoff as well as the dial that follows. It is observable only while
that cycle is still the current one. Failed means automatic recovery stopped
because retrying without user intervention cannot repair the failure. It is
observable only while no connection work is running; an explicit retry or
foreground re-proof starts a new Connecting activation and carries the prior
explanation as Standing Failure.
Connected means the session established a usable events path and is maintaining
it on a trusted Transport; a deliberate same-Transport subscription reinstall
stays Connected through its brief stream gap. Suspended means lifecycle
teardown deliberately stopped everything until the app is active again. A
foreground return that finds the connection still believed live proves it with
a ping and stays Connected while that ping is in flight, so a healthy trip out
of the app costs the user no churn.
The status never claims that stopped work is running, and never hides running
work behind a stopped condition. Whatever a surface then chooses to say is a
presentation question, answered by Standing Failure and Transport Error
Presentation.
_Avoid_: Agent Status, Reconnect Request, loading, syncing

**Agent Inventory**:
The Agents the Console believes a Host has. It is replaced wholesale when a
snapshot lands, never merged, because herdr replays no state on subscribe.
It becomes unknown when a Host Connection Status transition invalidates the
prior snapshot — so an empty Console during a connection problem means unknown
rather than none, and the window between a fresh Connected and its first
snapshot is loading rather than empty. A same-Transport subscription reinstall
is not such a transition and may keep the current inventory until its refresh
lands.
Readiness is a data condition and not a Host Connection Status: a Host is
Connected while its inventory is still unknown. Surfaces say the Agents are
loading there. They must not say the Host is connecting, and must never say a
pane is gone, which is answerable only once the inventory is known.
_Avoid_: agent list, snapshot state, syncing

**Standing Failure**:
The failure that last stopped automatic recovery on a Host, kept after the next
activation begins and discarded only when that activation resolves — by
connecting, by entering automatic recovery, or by failing again, which replaces
it.
It exists so Host Connection Status can report running work honestly without
the app withdrawing the explanation at the moment the user is reading it: a
Host re-proved on a foreground return is Connecting, and every status-derived
surface keeps presenting the Standing Failure until the activation answers,
except that a Reconnect Request may temporarily suppress the Host detail footer
while its button shows request progress. The failure remains stored and
continues to render on Agent detail, the Console, and the Hosts chip.
Only a failure that reached Failed becomes standing. A retryable failure inside
a recovery cycle does not, because nothing stopped and Reconnecting already
says what happened.
_Avoid_: last error, cached failure, sticky error

**Transport Error Presentation**:
What one `TransportError` is allowed to say to the user: a Summary naming what
happened, an optional Detail carrying the error's own interpolated text, and an
optional Recovery Suggestion naming something the user can do about it. It is
total over the error set and is therefore not only about connections — a
rejected herdr request means the connection worked — so it serves failed
one-off requests as readily as a stopped Host.
The Suggestion is optional because most errors do not support one: of the
errors automatic retry accepts, only an unreachable Host does. An API total
over the set may not promise that every case is actionable. Detail is the
error's own words, never authored instruction: a transport's failure string, or
herdr's own code and message.
Which parts a surface shows is decided by whether anything but the user can
change the outcome. A Failed Host shows the whole presentation, and so does a
failed one-off request wherever the surface has no more specific words of its
own, because in both cases nothing changes until the user acts. While
automatic recovery is running, no surface shows the Recovery Suggestion — an
instruction misstates who has to act and invites a restart that discards the
attempt already running — so Reconnecting shows the Summary, and, where the
surface is about one Host's connection health rather than about the Agents, the
Detail with it. Hosts sheet rows are chips rather than prose and sit outside
this term. A first-hop failure is presented against the Jump Host; where no
Jump-Host-directed text exists, the Suggestion is dropped rather than aimed at
the wrong machine.
This replaces Connection Guidance, whose name promised an instruction that the
retryable errors never carried.
_Avoid_: Connection Guidance, error message, connection error, retry hint,
actionable error

**Reconnect Request**:
A user's explicit Reconnect press on Host detail, and the brief window in which
the app shows that press being served. It is feedback about a request, not a
Host Connection Status: it is never derived from the status and never changes
it, an automatic Reconnecting is not a Reconnect Request, and a press in flight
suppresses the Host detail failure footer while driving the button's own
progress (#160).
_Avoid_: retry, reconnecting, manual reconnect state

**Background Grace Period**:
The window after backgrounding during which the app keeps running under an iOS background-execution assertion and holds its Host connections, so a short trip out of the app costs nothing on return. Only when it elapses does the app suspend and tear the connections down. Bounded by what iOS grants (tens of seconds); staying reachable for longer is what Agent Notifications are for.
_Avoid_: background mode, keep alive (that's the events session's ping)
