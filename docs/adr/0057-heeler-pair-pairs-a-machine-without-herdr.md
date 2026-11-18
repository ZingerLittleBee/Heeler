---
status: proposed
---

# `heeler-pair` pairs a machine without herdr, and Pairing ends on its Servers

Pairing ([ADR 0007](0007-pairing-via-herdr-plugin.md)) belonged
to the pairing plugin. Its popup runs inside Herdr TUI, and a scanned code
saved a Host with one Herdr TUI Server. A machine whose Servers are herdr-core
or tmux could not show a code: herdr-core has no plugin system, and the Host
Helper reaches a Host only after the app has connected
([ADR 0033](0033-herdr-core-hosts-run-a-heeler-host-helper.md)). Its first
device was added by typing an address, comparing a fingerprint and copying a
public key into `authorized_keys`.
[ADR 0047](0047-a-host-is-one-machine-and-lists-its-servers.md) had meanwhile
made a Host a machine that lists its Servers, which a Pairing Code ignored: it
always added a Herdr TUI Server.

The ceremony itself never needed herdr. The Bootstrap Key, its forced command
and Enrollment are OpenSSH and Node.

## Decision

- **`heeler-pair` shows the pairing screens outside herdr.** It is the
  plugin's pairing modules behind a second entry, `plugin/src/pair-cli.js`,
  published to npm as `heeler-pair` and started with
  `npx -y heeler-pair@latest` on macOS or Linux with Node 20 or newer. What
  `pair.json` holds arrives as `--port` and `--address`. Its ceremony state is
  under `$XDG_STATE_HOME/heeler/pairing`. The forced command it writes names
  the Node that ran it and the Enrollment entrypoint in npm's cache, which
  only have to outlive the code's two minutes.
- **The package is its own manifest over the plugin's sources.**
  `plugin/pair-cli/package.json` lists the modules the command loads, and a
  test holds that list to the entry's import closure. `make pair-cli`
  assembles the package from a commit on `main`, installs the tarball and
  starts it before publishing. The version is the package's own, so a release
  of the command does not make the app ask Herdr TUI Hosts to update their
  plugin.
- **It shows a machine code, Pairing Code v3.** The payload is a version 1
  payload under the same rules. The version says the code was shown outside
  any server and names none. An app that predates it answers with its
  "update Heeler" message. A v1 code from the command would have paired such
  an app into a Herdr TUI Host on a machine that may run no herdr.
- **Pairing ends on Add Host's last step.** After the verified reconnect the
  app saves nothing. It hands the login, every address the code offered and
  the pinned key to Add Host (ADR 0047), which trusts that key under the new
  record's id, runs the one look and shows the Servers step in the same
  sheet. The Host is saved there with the Servers the user checks. When its
  connection is already in the catalog, they are turned on there instead.
- **A Pairing Code replaces a key the catalog trusted.** When the connection
  is in the catalog and its records trust another key than the code pinned,
  the look goes by the code's key and the step says the key changed.
  Finishing leaves every record of the Host trusting that key and no other,
  so a retired key of another algorithm is not kept beside it, and asks a
  Console that had stopped on a failure to try again. Cancelling replaces
  nothing. Scanning the code is the user replacing the key, as Trust New Key
  is: the code came off the machine's own screen, and the ceremony
  authenticated with a Bootstrap Key only that code carried.
- **Codes from the plugin end there too.** A v1 code was shown inside a
  running Herdr TUI, so the step lists its default session as running even
  where the look finds no herdr, as from a login shell without it on `PATH`.
  That is the Server such a code has always added.
- **A v2 code keeps its own path.** Its Herdr Endpoint is one Herdr TUI
  Server that no look can find
  ([ADR 0023](0023-herdr-endpoint-in-pairing-code-v2.md)): the ceremony saves
  its Host, which opens on that Server's page, as before.

## Consequences

- The first device of a herdr-core or tmux machine needs no typed address, no
  fingerprint comparison and no hand-copied key. Native Windows still does:
  Enrollment is OpenSSH's forced command over a POSIX `authorized_keys`.
- A machine that runs Herdr TUI beside herdr-core or tmux gets all of them
  from one scan. A user who wants only Herdr TUI taps once more than before,
  on a step that says what else the machine runs.
- Pairing a Host whose connection is in the catalog no longer adds a second
  Herdr TUI Server. Its key is still pinned from the code, never asked about.
- A Host that stopped on a changed host key, or on a Device Key its machine
  no longer holds, is repaired by scanning a new code. Before, that scan
  added a second Host beside the one that stayed failed.
- Cancelling on the last step leaves the Device Key enrolled on the machine
  and no Host in the app. The command's last screen names the key and revokes
  it on one key press, as the popup's does.
- A look that fails after the ceremony shows Add Host's first step, filled
  in, with why. Save Without Connecting keeps the Host with no Server.
- `heeler-pair` needs Node and a route to npm on the machine. A machine with
  neither is added by hand.
- The npm package is a second thing to release, by hand, from `main`. A
  published version cannot be replaced, and the guides name the command, so
  it is published before the app version that mentions it.
- This amends the ADRs that tie Pairing to Herdr TUI: 0007 (the plugin is no
  longer the only thing that shows a code, and success no longer saves the
  Host), 0031, 0033, 0044 and 0047 (a Pairing Code no longer adds exactly one
  Herdr TUI Server, and herdr-core and tmux machines can pair).

## Alternatives

- **The entry in the Host Helper only:** the app installs the Helper after it
  connects, so it cannot pair a first device. It could carry the entry later,
  for a second device with no trip to npm.
- **A tmux `display-popup` binding or a herdr-core action:** each covers one
  server and needs it running. The command covers a machine with none.
- **A v1 code from the command:** older apps would pair, and save a Herdr TUI
  Host whose checks then fail with advice about herdr.
- **A `curl | sh` script or a standalone binary:** ADR 0007 rejected a
  standalone script because distributing it is an out-of-band step. `npx` is
  one command, as `herdr plugin install` is, and Node is already required by
  the Enrollment entrypoint. npm adds versions and an integrity check.
- **Save the Host first and choose Servers on Host detail:** that leaves a
  Host with no Server, or with a guessed one, for the user to tidy up. The
  Servers step exists for this choice.
- **Servers in the code:** the command would need a second detector in Node,
  beside the one the app runs through the login shell for the versions and
  paths it stores.
