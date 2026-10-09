---
status: accepted
---

# A Herdr Endpoint travels in Pairing Code v2

This decision is tracked in [Issue #380](https://github.com/ZingerLittleBee/Heeler/issues/380)
and shipped in [PR #430](https://github.com/ZingerLittleBee/Heeler/pull/430).

A desktop app can bundle its own herdr and run it with an isolated
`XDG_CONFIG_HOME`, with the binary inside its app bundle. Such a Host serves
the same `heeler` plugin, but its socket is not under `~/.config/herdr` and
its `herdr` is not on the SSH `PATH`. A Pairing Code v1 cannot say where that
herdr is, so a Host paired from one would talk to the wrong socket and run
the wrong binary.

Pairing Code v2 adds two required fields: `sock`, the absolute path of the
herdr API socket, and `herdr`, the absolute path of a launcher that behaves as
`herdr` for that instance. The app stores them on the Host as its Herdr
Endpoint. With an endpoint, every direct-streamlocal channel uses `sock`, and
every herdr exec runs the launcher as a positional argument of a POSIX
`/bin/sh -c` body with `HERDR_SOCKET_PATH` exported, with no `PATH` fallbacks.
A Host without an endpoint behaves exactly as before.

## Rationale

- **A new version, not additive v1 fields.** v1 decoders ignore unknown
  fields, so an older app would drop the endpoint and pair against the default
  socket without any error. Under v2 an older app refuses the code with
  `unsupported_version` and saves nothing.
- **Positional arguments, not quoted splices.** The launcher path usually
  contains spaces, and the existing wake, attach and config-dir commands
  already sit inside a single-quoted `/bin/sh -c` body. Passing the path as
  `"$N"` needs no nested quoting and keeps the login shell (fish, nushell)
  out of the parsing. Paths with `'`, `\` or ASCII control characters are
  rejected, matching the existing remote path rule.
- **The socket must use herdr's layout.** The plugin derives a hook's session
  from `HERDR_SOCKET_PATH` (ADR 0020). Requiring `…/herdr/herdr.sock` or
  `…/herdr/sessions/<name>/herdr.sock` keeps that derivation working, and the
  app writes the same session value into `notifications.json`. The socket is
  at most 96 bytes so that herdr's `-client` sibling, used by attach and wake,
  still fits macOS `sun_path`.
- **The launcher owns its config home.** The plugin config directory depends
  only on `XDG_CONFIG_HOME`. An endpoint that shared the user's own config
  home would share `notifications.json`, and registering the endpoint Host
  would evict the user's existing Host from its (device token, session) slot.

## Consequences

- v2 is decoded by the app only; the Node plugin keeps emitting and decoding
  v1. The wire contract and the launcher contract live in `plugin/README.md`.
- Endpoints are POSIX-only. A native Windows Host with an endpoint fails with
  explicit copy instead of reaching `herdr.exe` or a folder-path error.
- Preflight cannot discover sessions for an endpoint Host. It runs the
  launcher's `session list --json` as a probe instead, so a wrong launcher
  fails at "herdr installed" rather than later at attach.
- Exit 126 or 127 from the launcher's session list, plugin list or attach is
  reported as a missing launcher, not as herdr missing from `PATH`. A failed
  wake keeps the original socket error.
- Without the app's `PATH` prefixes, the launcher must give herdr a `PATH`
  on which the plugin's `node` and the user's agents resolve; a server it
  starts otherwise inherits sshd's minimal `PATH`.
- `heeler://agent` links that name a Host by address and session do not
  resolve to endpoint Hosts. Matching them would make links ambiguous for a
  user who also keeps a regular Host for the same machine.
- An older build ignores the endpoint and drops it on its next catalog save.
  Only TestFlight users can downgrade, so the endpoint stays in the same Host
  catalog.
