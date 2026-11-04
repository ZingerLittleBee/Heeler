---
status: accepted
---

# Update the Heeler plugin from the app

A Host's page shows a notice when its Heeler plugin is missing, outdated,
disabled or left beside an old copy, with the commands to run on the Host.
herdr has no request that installs a plugin (`plugin.enable` and
`plugin.disable` exist; installs are CLI only), so running those commands for
the user means running the herdr CLI over SSH exec.

## Decision

The notice's sheet offers an action whenever Heeler can run its commands
itself, typed as `HeelerPluginStep`s rather than shell text:

- **Install or update** runs `herdr plugin install ZingerLittleBee/Heeler
  --ref plugin --yes`, the notice's own command, not `herdr plugin update`.
  0.9.3 has no `update`; `update` keeps the ref recorded at install, so an
  install from before ADR 0026 would stay on `main`, and an install pinned to
  a commit never moves. The command names the Host's session, so herdr's
  protocol check before an install asks the server Heeler uses; a session
  without a server falls back to the shared registry.
- **Remove a leftover legacy id** runs `herdr plugin uninstall <id>` after any
  update.
- **Turn on** sends `plugin.enable` to the Host's own session, so it needs no
  `--session` and works for endpoint Hosts too.

The tap is the confirmation: the sheet shows the exact commands above the
action, session included, and `--yes` answers herdr's own prompt, which needs
a terminal anyway.

An install does not start over a newer plugin. herdr installs whatever the `plugin`
branch holds and compares no versions, while an app built ahead of the branch,
or a Host installed from `main` or a commit, can have a newer plugin than the
branch. So before an install, the action rereads the Host's plugin over its
own connection (another device may have changed it since the checks). It
stops, with nothing changed, unless that plugin is absent or is still one the
notice would replace (current id, a GitHub install of this repository) with a
version herdr read from its manifest. It then reads the branch's
`herdr-plugin.toml` with the Host's own git, the way herdr's install fetches
it, and stops when the branch cannot be read. When the branch is older, it
skips only the install and still runs the action's other steps, such as
turning the plugin on. The branch only moves forward (ADR 0026: append-only,
and changed content needs a newer version), so the version read is the least
herdr then installs. A refusal keeps the status the sheet was showing, so
its action stays in place to explain why nothing changed.

No install of any kind is offered over an unreadable manifest: herdr then
reports the version from its registry, which may be stale, so the app cannot
rule out a downgrade. The sheet still shows the commands.

The check and herdr's replacement are not atomic, and herdr compares no
versions. It fetches the target before taking its installation lock, so
until this install takes that lock another one can still put a newer plugin
on the Host and then be replaced: a plugin installed by hand from `main` or
a commit, or another device's install of a newer branch version published
while this install's older download was under way. Both need a second
install within the same seconds.

Steps run in order on a connection the Host page opens for them, as the
preflight does. The Console's connection redials after a timeout and retries
the operation, which would run an install twice. The first failure stops the
action; install comes first, so a failed install never leaves the Host
without the copy it had. The outcome is the plugin list read back over the
same connection, not exit status. An install gets its own 180 s budget
because herdr bounds neither the fetch nor `npm ci`. When the budget runs out,
the sheet says the change may still finish, since it can.

The install inherits the exec's `PATH`, and so does the plugin's `npm ci`
build. SSH exec reads no interactive shell setup, where most Node.js installs
put themselves on `PATH`, so an install first runs `NodeToolchainProbe` in
the same exec. It takes the first directory whose `npm` runs and whose
`node`, the one `PATH` finds with that directory first as npm's
`#!/usr/bin/env node` does, is 20 or newer (the plugin's `engines`). An npm
upgraded into its own prefix, such as `/usr/local/bin` after
`npm install -g npm`, therefore still pairs with the system's node. The
places, in the order an interactive shell usually ends up with:

1. Version managers' defaults: mise, Volta, fnm, nvm (`nvm which default`),
   asdf, nodenv, nvs, nodebrew, n, proto and pnpm, each at its own
   environment override or default location.
2. The exec's `PATH` with the app's prefixes (`HerdrHostPath`): Homebrew and
   system packages.
3. Homebrew's own directories (an endpoint launcher gets no prefixes) and
   versioned formulae, Nix profiles, snap and MacPorts.
4. The login shell's `PATH` (`$SHELL -lic /usr/bin/env` for bash, zsh, fish
   or ksh), kept whole behind npm's directory because shims may need other
   tools on it, with a 10 s watchdog because rc files can wait for input.
   The watchdog ends the login shell and the commands it started directly;
   without a terminal, dash and busybox have no job control, so anything
   those started in turn runs on.

Running `npm --version` rejects a shim with no version selected and a broken
install. That directory goes first on `PATH`; `herdr` itself is resolved
before, so a `herdr` beside Node.js cannot replace it. Without one, the
probe stops before herdr fetches anything and the sheet says Node.js is
missing, names the old version it found, or names a new enough node that
has no npm (Debian and Ubuntu package them apart). The probe also runs before an
endpoint launcher, which herdr still reaches by its path; ADR 0023's rule is
about which `herdr` runs, not about `npm`. The user fixes the Host; Heeler
does not fall back to typing the command into a terminal.

`scripts/test-node-toolchain-probe.py` (`make test-tools`) runs the probe
against fake layouts under each POSIX shell present, including dash in CI.
Observed on Debian 12, with each manager's own installer and the probe run
under `env -i` with `PATH=/usr/bin:/bin`: nvm, fnm, Volta, asdf 0.14 and
0.16, nodenv, n, mise, pnpm and Node.js on `PATH` only through `.bashrc` or
`.zshrc` were found; Debian's Node.js 18 was reported as too old. On Debian
13, Node.js 20 without the `npm` package was reported as missing npm, and an
npm upgraded into `/usr/local/bin` ran with `/usr/bin/node`.

No install is offered over a plugin that is not a GitHub install of this
repository: herdr refuses to replace a linked checkout and may refuse an
unknown source, and a fork's install would quietly move to this repository.
A GitHub install whose repository herdr does not report may be a fork too.
Turning such a plugin on, or removing a leftover legacy id, still is. No
action at all is offered on native Windows Hosts (no plugin) or for a plugin
installed under a legacy id. Moving to the current id changes which config
directory Notification Registration uses, and the Console's transport caches
that directory until it reconnects.

## Consequences

- Observed on herdr 0.9.5: a failed fetch or build leaves the previous
  plugin registered and enabled. A connection lost mid-install leaves either
  the old or the new plugin, never a partial registration, plus herdr's
  temporary directories (see [herdr compatibility](../agents/herdr-compatibility.md)).
- Running hooks pick up the new plugin at the next event; the plugin's
  startup hook waits for the next server start.
- A CLI newer than the running server refuses the install until the server
  restarts; the sheet names that cause, as it does for build and download
  failures.
- The installed version can only be as new as the `plugin` branch. An app
  built before its plugin was published still sees an outdated plugin after
  a successful install, and the sheet names the published version herdr
  installed.
- An install that replaces a plugin fetches the branch twice, once for the
  version check and once in herdr, a few seconds on a typical link.

## Alternatives

- **Open a Shell Terminal and type the command**: the user's interactive
  shell would find Node.js more often, but it needs a running session,
  takes the Host's one interactive terminal, and leaves a tab behind.
  Reporting the failure was preferred.
- **Run the whole install in the login shell** (`$SHELL -lic`): it would see
  what a terminal sees, but every rc file then runs around herdr for the
  whole install, a prompt such as mise's trust check can hold it until the
  budget runs out, and the `herdr` it finds may differ from the one Heeler
  uses elsewhere. The probe asks the login shell only for `PATH`, last and
  bounded.
- **Read the branch's version from the phone** (GitHub's raw file host): no
  second fetch on the Host, but the phone may not reach GitHub where the Host
  does, and the Host's git is what herdr uses.
- **Install the checked commit** (`--ref <sha>`): the version check would be
  exact, but herdr records the ref, so `herdr plugin update` would stay on
  that commit afterwards.
- **A detached install polled through a log file**: survives the app being
  suspended, at the cost of log locations, orphan cleanup and polling. A
  plain exec leaves the Host on one version or the other when interrupted,
  and the sheet says the change may still finish when the connection ends
  before the read back.
