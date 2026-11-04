---
status: accepted
---

# The plugin generates the launcher for a relocated herdr

[ADR 0023](0023-herdr-endpoint-in-pairing-code-v2.md) added Pairing Code v2
for a herdr outside the user's config home, and expected an app that bundles
herdr to produce it. A herdr started by hand with its own `XDG_CONFIG_HOME`
(a per-project instance, or one of several profiles behind a wrapper script)
runs this plugin too, but the plugin only emitted v1, and nothing on such a
Host knows how to start herdr for that instance over SSH.

## Decision

- The popup treats its herdr as relocated when `HERDR_PLUGIN_CONFIG_DIR` is
  not `~/.config/herdr/plugins/config/<id>`, compared as real paths, so a
  profile nested inside `~/.config/herdr` counts too. That directory follows
  only `XDG_CONFIG_HOME`, the separate config home ADR 0023 requires, and
  herdr sets it in every plugin pane. The code's `sock` is `HERDR_SOCKET_PATH`.
- Unless `pair.json` names a `launcher`, the popup writes one into its config
  dir each time it opens. It re-exports `PATH`, the XDG base directories, and
  the `HERDR_*` variables herdr does not set per process, then `exec`s
  `HERDR_BIN_PATH`. The popup runs inside the server, so these are the
  settings the server was started with.
- The launcher goes in a code only after a test run of `plugin config-dir`
  through it, from a minimal environment, returns this plugin's config dir.
  A generated launcher is tested under a staging name before it replaces the
  previous one, in a config dir only the user can write.
- A relocated herdr whose `HERDR_PLUGIN_STATE_DIR` is the default
  `~/.local/state/herdr/plugins/<id>`, or that gets
  no working endpoint, is not paired: the popup says why and offers no code.
  A v1 code would pair the phone with the user's default herdr, the mistake
  v2 exists to prevent.

## Consequences

- A relocated herdr pairs with no setup. `pair.json` `launcher` remains for
  instances whose environment the popup does not carry.
- The Host runs a file the plugin wrote, with the user's own permissions,
  from a directory only that user can write. It holds the environment the
  server started with, which is already readable by that user.
- The launcher captures the environment at pairing time. Opening the popup
  again rewrites it in place, so the phone's stored path stays valid; a
  rewrite that fails its test run leaves the old launcher in place.
- A herdr that keeps the user's config home but listens on another socket
  still gets v1, with a warning: an endpoint there would share
  `notifications.json` with the user's own herdr.
- The probe runs once per popup, synchronously after the first paint like
  the Tailscale probe, and is bounded at 5 seconds.

## Alternatives

- **Falling back to a v1 code with a warning:** keeps pairing possible, but
  with the wrong herdr, and the warning is easy to miss.
- **A required `pair.json` launcher:** works, but leaves every user to write
  the same wrapper by hand, and a wrong one surfaces only at attach.
- **Deriving the instance from the socket path:** recovers `XDG_CONFIG_HOME`
  but not `XDG_STATE_HOME`, the binary, or a `PATH` on which `node` and the
  agents resolve.
- **Probing on every repaint:** follows `pair.json` edits live, at the cost of
  running herdr per keypress.
