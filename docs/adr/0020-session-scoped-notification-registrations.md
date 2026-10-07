---
status: accepted
---

# Session-scoped Notification Registrations owned by Notification Key

This decision is tracked in [Issue #412](https://github.com/ZingerLittleBee/Heeler/issues/412)
and shipped in [PR #416](https://github.com/ZingerLittleBee/Heeler/pull/416).

Hosts that reach the same remote user share one `notifications.json`: the
plugin config directory depends only on that user's config home, never on the
address, port, or herdr session. Every herdr session of that user runs the
plugin's hooks, and pane ids repeat across sessions.

Each registration entry therefore carries `session` (`""` for the default
session, otherwise the session name). A hook reads its own session from
`HERDR_SOCKET_PATH` and delivers only entries of that session plus **legacy**
entries (no string `session`), which keep today's every-session behaviour for
older apps. An unrecognized socket path delivers legacy entries only.

A Host's own entry is the one carrying its Notification Key. Keys are random
per Host, so the key identifies the owner whatever the Host's address, port, or
session; `session` is a field of that entry, not its identity. The app keeps at
most one entry per (device token, session): registering takes the slot, so two
Hosts on one session (LAN and Tailscale) share it and the last to register
wins. Loading a Host moves its own entry to the Host's current session, or drops
it when another Host holds that slot.

Read-modify-writes from the Settings store and the Live Activity coordinator go
through one app-wide `GitExecGate`, taken after the transport is acquired and
held only around the read and replace of `notifications.json`.

## Rationale

- Keying ownership by session or endpoint fails for real setups: a session edit
  strands the old entry, and one server is often reached at several addresses.
  The key is already per Host and already routes pushes (`kid`), so it costs no
  new state.
- A remote lock or a per-Host slot file was rejected as heavier than the
  problem. Writers are one app per device, so in-process serialization covers
  the lost updates that matter.
- Legacy entries stay deliverable everywhere so a new plugin never silences an
  old app.

## Consequences

- The `session` field and its legacy meaning are a wire contract with every
  installed plugin since 0.6.0; changing them needs a versioned migration.
- A new app with a pre-0.6.0 plugin still cross-delivers between sessions and
  can deliver one event twice, until the plugin is updated.
- On upgrade, several Hosts that shared one pre-#412 entry keep only the Host
  whose key the entry carried; the others read Off until turned on again. The
  app does not re-register them automatically, because that would be a remote
  write the user did not ask for.
- Same-session Hosts cannot both receive notifications for one device.
