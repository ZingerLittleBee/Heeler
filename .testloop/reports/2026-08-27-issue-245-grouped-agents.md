# testloop — 2026-08-27 — Issue #245 grouped Agents

**Verdict:** pass · **Rounds:** 2

## Covered

- Switched between the flat Status Order list and the By Host presentation,
  confirming Host headers, grouping, and the absence of duplicate Host status.
- Collapsed and expanded a live Host section, including its Done-Agent
  attention count and accessible name, value, and action hint.
- Terminated, rebuilt, installed, and relaunched the app, then independently
  confirmed that both presentation mode and per-Host collapse state persisted.
- Restored the final app state to Status Order without opening an Agent or
  changing Host or Agent data.

## Found & fixed

- None.

## Still open

- Host-filter composition was not exercised because only one Host was
  configured.
- Empty and unavailable Host presentation was not exercised because the live
  Host was connected and non-empty.
