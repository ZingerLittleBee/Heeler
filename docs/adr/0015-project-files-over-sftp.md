# 15. Project Files browse and edit over the app's own SFTP

Date: 2026-08-20

## Status

Accepted

## Context

The iPad push (Files browser + code editor linked to workspaces) needs remote
filesystem access. Two decisions looked open and were not:

1. **Where file operations run.** The herdr 0.8.0 API exposes no filesystem
   methods — its 90 request methods read panes and agents, never paths. A
   plugin could add file RPCs on the Host, but that puts a Host-side
   prerequisite in front of a feature that only needs what SSH already
   grants, and it would re-implement SFTP badly. The app already owns a
   pinned libssh2 with an SFTP surface (ADR 0006) and a channel-admission
   budget sized against sshd's `MaxSessions`.

2. **What renders the code.** Tree-sitter editors (Runestone and its grammar
   tree) buy quality highlighting with a dependency graph this repository
   would have to pin, review, and re-review per grammar. Every other
   dependency here is either vendored-and-hash-pinned or absent by design;
   the notification plugin and Push Relay are deliberately zero-framework.

## Decision

File browsing, reading, and writing ride the app's own SFTP client behind the
existing `Transport` protocol: `listDirectory`, `readFile` (byte-capped),
`writeFile` (atomic temp + rename), `statFile`. Each operation admits one
`.ordinarySession` channel, exactly like attachment staging. herdr is not
involved; the workspace's `checkout_path`/launch cwd is the only thing the
wire contributes (the same root the Skills probe uses).

The editor is a plain `UITextView` with a repository-owned, single-pass token
highlighter (comments, strings, numbers, keywords per extension family) —
the Neon-Vision-Editor shape, not the IDE shape. Saves stat first and surface
a conflict rather than clobbering a file an agent just rewrote.

## Consequences

- Works against any Host the moment SSH works; no plugin version to gate on.
- Highlighting is lexical only: no scopes, no incremental parse, no folding.
  If that ceiling starts to hurt, revisiting Runestone is a contained swap —
  the editor view is one file behind stores that know nothing about rendering.
- Whole-file reads are capped (2 MiB in the UI) because SFTP has no server-side
  pagination; huge files fail fast with an honest size, never a partial buffer.
- An agent and the editor can race on the same file. The stat-before-write
  conflict prompt is the chosen mitigation; file watching/locking is not.
