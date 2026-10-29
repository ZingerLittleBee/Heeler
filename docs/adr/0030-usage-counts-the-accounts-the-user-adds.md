---
status: accepted
---

# Usage counts the Accounts the user adds

[ADR 0028](0028-plugin-collects-agent-usage-on-the-host.md) read one Claude
Code sign-in per Host and merged every Claude Code config directory it knew
into one Token Usage total (#494, story 24). Some users run two Claude Code
subscriptions side by side on one Host, the second started with its own
`CLAUDE_CONFIG_DIR` in that Agent's environment only (#529). herdr's
environment never names that directory, so its Transcripts and Usage Limits
are invisible, and a merged total could not tell the subscriptions apart
anyway.

## Decision

- An Account is one config directory. Claude Code itself uses exactly one:
  `CLAUDE_CONFIG_DIR` when set, else `~/.claude`. The Default Account is the
  directory Claude Code uses in herdr's recorded environment, with the legacy
  `${XDG_CONFIG_HOME:-~/.config}/claude` folded in. When herdr's environment
  sets `CLAUDE_CONFIG_DIR`, `~/.claude` is no longer merged into it; it becomes
  a suggestion the user can add as its own Account. This replaces story 24's
  merge, which paired the Token Usage of two directories with the Usage
  Limits of one.
- Further Accounts count only after the user adds them. Without any, usage is
  read exactly as before. The plugin suggests directories from two cheap
  signals and never walks the disk:
  - the initial environment of running Claude Code Agents, found through
    herdr's `pane.process_info` pid (`ps -E` on macOS, `/proc/<pid>/environ`
    on Linux), from which only `CLAUDE_CONFIG_DIR` is kept;
  - one directory listing each of `$HOME` and `~/.config`, keeping
    `.claude*` directories that hold Claude Code's own `.claude.json` or a
    `projects/` directory.

  The user can also pick any directory with the remote directory browser; it
  must hold `.claude.json` or `projects/`.
- The Account list lives on the Host, in the plugin's config directory, and
  the app writes it over SFTP. Every device and every Host entry that
  resolves to that directory shares it, which is right: they share the same
  home and therefore the same Claude Code directories.
- Usage Limits are read and shown per Account and never merged. The existing
  per-Host Claude Code toggle covers every Account; each Account has its own
  `get_usage` throttle and back-off. Token Usage keeps the Host total and
  adds a per-Account breakdown.
- A directory that resolves to one already counted is refused. The plugin
  does not try to recognize the login behind a directory, so two directories
  signed in to the same login are two Accounts, and `/login` inside one
  directory stays one Account.
- Only Claude Code gains Accounts for now. Codex keeps its single
  `${CODEX_HOME:-~/.codex}` home, though the same model would fit it.

## Considered Options

- **Keep merging every directory into one total**: rejected. Separate
  subscriptions have separate limits, and one figure cannot say which is near
  its limit.
- **Add every detected directory automatically**: rejected. A copied backup
  of a config directory looks like an Account and would double the totals;
  the user decides what counts.
- **Manual choice only**: rejected as the only path. The Agent environment
  names arbitrary locations such as `~/.ccs/instances/<name>` exactly, and
  costs one process lookup per new Agent process.
- **Keep the list on each device and pass it to the query**: rejected. Each
  device's list would change the cache key, so the same Transcripts would be
  scanned once per device, and the list describes the Host, not the device.
- **Recognize the login by reading `.claude.json`**: rejected. Its account
  record carries the user's email, which the `usage` contract never carries,
  and the plugin stays away from sign-in data.
- **Recursive discovery under `$HOME`**: rejected. It costs orders of magnitude
  more and enters folders macOS privacy protection guards.
- **Derive the directory from the Transcript path herdr's hook reports**: not
  available. herdr 0.9.5 keeps that path only for Pi and Oh My Pi and reduces a
  Claude Code session to its id.

## Consequences

- Users whose herdr environment sets `CLAUDE_CONFIG_DIR` and who also have a
  `~/.claude` lose that directory from the Default Account until they add it
  as an Account.
- The plugin reads the environment of the user's own Claude Code processes.
  It keeps only `CLAUDE_CONFIG_DIR`, and only as a suggestion.
- An Agent started from a second Account's directory still lacks herdr's
  Claude Code hook, which herdr installs into one directory only, and Chat
  looks for Claude Code Transcripts under `~/.claude` only. Chat for such
  Agents is a separate problem.
