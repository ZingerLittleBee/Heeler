---
status: accepted
---

# Accounts for every harness, and Launch Presets that name a folder

[ADR 0030](0030-usage-counts-the-accounts-the-user-adds.md) gave Claude Code
Accounts, kept in the Host's `usage-accounts.json` and edited from Usage.
Users run second sign-ins of other harnesses too (a second `CODEX_HOME`, a
work Gemini CLI home), Chat could not find a conversation kept in any
directory but the Default Account's (#621), and users started those Agents
with shell aliases that set the folder variable and flags by hand (#622).

## Decision

- Accounts are kept for every harness Heeler supports, in one place:
  Settings › Agents & Accounts, per Host. Usage no longer edits them.
- The file stays at `version: 1`. Its `claude` section keeps its place and
  shape, so plugin 0.8.0 reads it unchanged; every other harness has its own
  section under `programs.<kind>`, with the same `accounts` and `ignored`
  lists and an optional `variable`. Unknown sections and fields are kept on
  write, so an older app never drops what a newer one wrote.
- A harness's Account is a directory, checked for that harness's own marker
  files where Heeler knows them (`auth.json` for Codex, `sessions/` for Grok
  and Pi); any directory is accepted for the rest.
- A harness's Folder Variable is known for Claude Code, Codex, Grok, Pi and
  Gemini CLI. For the others the user names it once per Host; without one,
  the harness's Accounts are found by Chat but cannot be launched.
- Chat searches the Default Account first, then each added Account, and skips
  a directory the Host refuses to read instead of failing the search.
- Usage counts Claude Code and Codex Accounts (plugin 0.9.0 adds Codex,
  reading `CODEX_HOME` per Account). Other harnesses report no Usage today.
- Launch Presets are kept on the device and name an Account by its folder
  (`~` allowed), not by its id. A preset therefore works on every Host that
  has that folder, and removing an Account leaves presets that name its
  folder untouched. A preset's own variables win over its Account's.

## Considered Options

- **A new file or `version: 2`**: rejected. Plugin 0.8.0 reads a file of any other
  version as empty and would stop counting Claude Code Accounts on Hosts that mix app
  versions.
- **Presets kept on the Host**: rejected for now. Presets are a device's
  launch habits across Hosts; the Account's folder is what is Host-specific,
  and it is resolved on each Host at launch.
- **Presets that point at an Account id**: rejected. Ids differ per Host, so
  one preset could not start the same setup on two Hosts, and removing an
  Account would silently change what a preset launches.
- **Fixed aliases such as `c` and `cg`**: rejected as the model. They hard-code
  one harness and one folder; a preset is the same idea, named by the user
  and editable.

## Consequences

- An Account's variable a preset sets is resolved per Host at launch, so a
  harness with no known or named variable cannot launch an Account.
- Removing an Account does not warn about presets that name its folder; the
  removal message says they keep setting it.
- A worktree launch with environment variables creates its Workspace's tab
  with the variables and closes the root pane, because herdr's
  `worktree.create` takes no environment.
