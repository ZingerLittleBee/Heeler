# herdr-mobile

A native iOS agent console for herdr. One context: the app. Terms owned by herdr keep herdr's meaning; this glossary pins how we use them client-side.

## Language

**Host**:
A remote machine reachable over SSH that runs a herdr server. The unit a user adds, names, and authenticates against.
_Avoid_: server, machine, connection

**Agent**:
A coding agent process (claude, codex, ...) running inside a herdr pane, as reported by herdr's detection. The primary object of the app.
_Avoid_: bot, task, session

**Agent Status**:
herdr's detected state of an Agent: Idle, Working, Blocked, Done, or Unknown. Blocked means the agent is waiting for human input and drives sort order and (later) notifications.
_Avoid_: agent state, activity

**Pane**:
herdr's unit of terminal real estate that an Agent lives in. Used as an address (`pane_id`), never as a layout concept in this app.
_Avoid_: window, tile

**Console**:
The native dashboard surface: the flat, status-sorted list of Agents across Hosts, plus the Agent detail screen.
_Avoid_: dashboard, home

**Observe**:
Read-only live view of an Agent's terminal output. It temporarily claims a
non-takeover herdr control session so the Agent's PTY matches the phone
geometry, but never sends terminal input; replies and keys use native controls.
_Avoid_: watch, monitor, preview

**Attach**:
Full interactive terminal control of an Agent's pane through the embedded terminal.
_Avoid_: takeover (that's herdr's flag, not our surface), connect

**Terminal Keyboard**:
The input surface used only within Attach to send text and terminal key sequences to an Agent's pane. It models terminal input, not remote-computer hardware events, and never appears in Observe.
_Avoid_: computer keyboard, remote keyboard, Observe keyboard, reply keyboard

**Dictation**:
Hold-to-talk voice input on the Agent reply box. Speech is transcribed on
device into the draft for the user to review and send; it never sends by
itself and never produces terminal input directly.
_Avoid_: voice message, audio recording, voice command

**Transport**:
The app-side abstraction that executes herdr API requests and delivers event streams over SSH. UI code talks to Transport, never to SSH primitives.
_Avoid_: client, bridge, tunnel
