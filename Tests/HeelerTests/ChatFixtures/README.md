# Chat fixtures

Captured inputs for the native Chat tests. The test bundle carries this
directory as a folder reference (`project.yml`), and
`Tests/HeelerTests/Support/ChatFixture.swift` loads files by their path below
this directory.

## Provenance

All captures come from live probes against an isolated herdr backend on
2026-10-06: herdr 0.9.3 (protocol 22), Claude Code 2.1.291 and Codex 0.160.1.
None came from a personal session.

| Path | Source |
|---|---|
| `claude/probe1-transcript.jsonl` | First probe: Claude Code session with Bash, AskUserQuestion, plan mode and Write permissions |
| `claude/probe2-transcript.jsonl` | Second probe (session `e951205e-24af-4a5e-baa7-3ccbebd2de2c`): declines with and without feedback, notes on approvals, multi-question AskUserQuestion, plan mode, Edit/WebFetch declines, a background subagent, parallel Bash |
| `claude/probe2-subagent.jsonl`, `.meta.json` | The background subagent the second probe launched (`agent-a9985bf0a8b4ebbe3`) |
| `codex/probe1-rollout.jsonl` | First probe: Codex rollout with exec approvals and `request_user_input` |
| `codex/probe2-rollout.jsonl` | Second probe: paginated rollout with approvals, declines, sync and async questions, interrupted turns and parallel commands |

## Scrubbing

The probe tooling already re-serialized each JSON line, replaced attachment
bodies with `{"type": …, "redacted": true}` and thinking text with
`<redacted>`. Real transcripts are compact JSON, so tests parse lines and
never compare bytes with a live file.

Copying them here also rewrote:

- `/Users/<name>` and its project-key form `-Users-<name>` to `/Users/dev`
  and `-Users-dev`;
- the probe root `heeler-iso-chat` to `heeler-chat`.

Byte offsets in tests refer to these scrubbed files. After adding a capture,
check that searching this directory for `/Users/` (other than `/Users/dev`),
`ghp_`, `Bearer` and e-mail addresses finds nothing.
