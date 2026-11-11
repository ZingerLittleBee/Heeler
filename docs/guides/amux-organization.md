# Browse amux organization on a Core Host

Heeler reads `amux-organization` on the existing herdr-core connection. In
Console > Terminals, **amux Spaces** opens its ordered Spaces, Worktrees, Tabs
and terminal membership, including empty Worktrees and missing members.
Worktree cards and the New Agent / New Terminal Workspace pickers also use
the shared names. The browser includes Agents as well as ordinary shells.

The plus menu beside a Space or Worktree starts a Terminal or Agent in its
absolute Host-side path. A launch does not join that Space, Worktree or Tab:
the new Terminal is unassigned until placed explicitly from amux. It remains
discoverable in Console in the meantime. No document or organization label
is written, and window placement, Panels, selection and focus are not copied.

## Read contract and provenance

The frozen contract is **amux organization v1**, from
`zinger-labs/amux` integration revision
`b173a167535c6a0af50a69736687e2e9a419ef00`,
`docs/contracts/herdr-core.md`. Its shared
[`organization-v1.json`](../../plugin/test-vectors/amux-organization-v1.json)
is copied byte-for-byte from `Tests/Fixtures/herdr-core/organization-v1.json`.
Implementation scope is [amux #161](https://github.com/zinger-labs/amux/issues/161),
within [#141](https://github.com/zinger-labs/amux/issues/141).

- Only the Core envelope's `value` is organization. `schemaVersion: 1` is
  distinct from the Core CAS `version` (7 in the fixture).
- `coreID` must exactly match the connected Core. All Space / Worktree / Tab
  IDs are nonempty, opaque and unique across their entity type. Each terminal
  address occurs at most once, with no relayed addresses.
- Ordered `spaces: [{id, name, path, worktrees}]` contain ordered
  `worktrees: [{id, name, path, tabs}]`, including the main checkout. Tabs are
  ordered `{id, name, terminals: [address]}`. Names are strings, paths are
  absolute Host paths, and empty arrays are valid.
- Unknown fields are ignored, never rewritten. Missing, invalid, oversized
  (over 1 MiB serialized value), unsupported or wrong-Core metadata falls
  back to ordinary Core discovery and existing herdr-app organization.
- Snapshots, missed-event refresh and local `doc` events refresh the read.
  Reconnect discards the old amux read. Deleted targets and targets from a
  replaced Core cannot be used to launch. Launches are not retried.

Phone Workspace identities include the Core identity and amux entity ID, not
the name or cwd. Cwd and parent hints do not add amux membership. A Worktree
does not become removable from Heeler merely because amux lists it.

## Development checks and final acceptance

`make test-app TEST_SELECTOR='HeelerTests/HerdrCoreConsolePlacementTests'`
exercises Console membership, order, empty checkout launches, no organization
writes, invalid metadata fallback, document refresh/deletion and identity
replacement over disposable scripted transports. It also hosts the native
browser and exercises its launch menu. The same suite retains ordinary
herdr-app and derived-Core negative controls. `HerdrCoreLaunchTests`,
`HerdrCoreConsoleProjectionTests`, `HerdrCoreWindowsConsoleTests` and
`StartAgentStoreTests` cover the existing launch and Console paths.

These are development checks, not final mobile acceptance. Still required:
real iPhone pairing through amux's future v3 endpoint; organization and cwd;
existing and newly launched terminal input; initial unassigned state and
explicit placement from amux; reconnect/revocation; ordinary Core/herdr-app
and TUI real-device negative controls; exhaustive native/input/platform
acceptance. Pairing/Enrollment (#160), amux's Swift helper, notifications and
Live Activity remain separate implementations. None is claimed by this reader.
