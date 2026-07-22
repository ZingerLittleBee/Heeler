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

**Attach**:
The Agent detail surface: full interactive terminal control of the pane through
the embedded terminal. The normal terminal buffer uses native local scrollback.
Alternate-screen TUIs map vertical touch drags and momentum to terminal wheel rows.
Touching the terminal never opens the software keyboard; the keyboard toolbar
button is the only entry point, so a scroll gesture cannot be interrupted by a
keyboard-driven viewport resize.
_Avoid_: takeover (that's herdr's flag, not our surface), connect

**Terminal Keyboard**:
The two input modes used within Attach. Text keeps the standard iOS input method
for composition, autocorrection, dictation, and language switching. The Keys mode
replaces it with a compact terminal control pad for navigation and common control
signals.
Both modes send directly to the Agent's pane.
_Avoid_: desktop keyboard, reply keyboard

**Transport**:
The app-side abstraction that executes herdr API requests and delivers event streams over SSH. UI code talks to Transport, never to SSH primitives.
_Avoid_: client, bridge, tunnel
