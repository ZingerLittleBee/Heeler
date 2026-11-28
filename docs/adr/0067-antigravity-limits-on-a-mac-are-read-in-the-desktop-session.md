---
status: accepted
---

# Antigravity limits on a Mac are read in the desktop session

Antigravity CLI keeps its token in the login Keychain on macOS. An SSH exec
and the Host Helper's `user/<uid>` LaunchAgent cannot read that Keychain
([ADR 0033](0033-herdr-core-hosts-run-a-heeler-host-helper.md)). A print-mode
`agy -p "/usage"` that cannot read its token does not fail: it starts a
browser sign-in and waits for it. The Helper runs `agy` with the recorded
environment, which carries no `SSH_*` variable, so `agy` opened its sign-in
page in the Mac's browser on every Usage read and Heeler killed it after
15 seconds as a timeout. On the owner's Mac that was every Helper read from
2026-11-24 to 2026-11-28 ([herdr compatibility](../agents/herdr-compatibility.md),
Antigravity CLI's Usage Limits read on a real Mac). The maintainer asked on
2026-11-28 for a fix or another way to read the limits.

## Decision

- **No `agy` without the Keychain.** On macOS, `readAgyLimits` starts `agy`
  only after `security show-keychain-info` succeeds in its own session.
  Otherwise the reading is `keychainUnavailable` and no `agy` starts. This
  guards every route: an SSH exec, herdr's `usage-agy-limits` action, and the
  job below.
- **The Helper reads through the desktop session.** When the Helper's Usage
  worker on macOS cannot use the Keychain, it reads through a one-shot
  launchd job in `gui/<uid>`, as the GitHub tab does for `gh`
  ([ADR 0065](0065-the-github-tab-runs-gh-on-a-host-and-holds-no-token.md)).
  The worker writes a request with a fresh token and a job plist into the
  Usage cache directory. It boots out any job left under the label,
  bootstraps the new one, and polls for the answer that carries its token
  for up to 25 seconds, as the plugin waits for herdr's action. Then it boots
  the job out and removes the plist and the request. The job runs the
  recorded Node.js with `usage-agy-reader.js --config <runtime directory>`,
  which answers through the same `answerAgyLimitsRequest` as herdr's action,
  so the Keychain check guards it too.
- **One label per Usage cache.** The label is
  `dev.bybee.heeler.usage-agy.<cache key>`. The worker lock in that
  directory already lets one worker read at a time.
- **`ProcessType` Interactive.** Without it, launchd throttled the job. In
  two of three runs `agy` was still starting when it reached its 15-second
  limit, and in the third it reached `/usage` but did not finish. With it,
  the first read took 14 seconds and the next five 6.2 to 8.4 seconds, about
  what a desktop terminal takes.
- **No desktop login, no job.** With nobody logged in at the desktop there is
  no `gui/<uid>` domain, the bootstrap fails, and the worker reads in place,
  which answers `keychainUnavailable`. Linux is unchanged.

## Considered options

- The Keychain check alone. No browser opens, but a Mac reached over SSH
  would never show Antigravity limits.
- The Helper's LaunchAgent in `gui/<uid>`. ADR 0033 rejected it: it cannot
  be installed while nobody is logged in, and it stops at logout.
- Passing the exec's `SSH_*` variables to `agy`. `agy` then prints the
  sign-in URL instead of opening it, but it still cannot read its token and
  still waits until it is killed.
- `AGY_CLI_NONINTERACTIVE_HEADLESS` or `AGY_CLI_INTERACTIVE_HEADLESS`, names
  found in the 1.5.19 binary. Neither stopped `agy` from opening the browser.
- Typing `/usage` into a running `agy` TUI. It works only while one runs, it
  interrupts the person using it, and it reads a screen.
- Reading `agy`'s Keychain item or calling its local language server. Heeler
  never reads a program's credentials, and the server's API is undocumented.

## Consequences

- The Helper now starts `/bin/launchctl`. The Helper closure test lists it
  with the other programs the Usage worker may start.
- Each macOS read from SSH loads one job in the user's desktop domain and
  removes it within the read. The plist exists only while the read runs.
- A signed-out `agy` in the desktop session still opens its sign-in in the
  browser, as it does through herdr's action. Its timeout is cached for
  5 minutes, like any failed read.
- Claude Code's Usage Limits through the Helper still answer
  `keychainUnavailable`. The same job could read them, but does not yet.
- Host Helper 0.5.14, not yet released, carries the job. The herdr plugin's
  Keychain check ships with the plugin's next version.
