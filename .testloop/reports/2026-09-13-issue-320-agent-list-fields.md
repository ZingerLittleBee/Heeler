# testloop — 2026-09-13 — issue-320-agent-list-fields

**Verdict:** pass · **Rounds:** 4

## Covered

- Agent List Fields on the iPhone Simulator with a saved catalog written by
  another build (herdr's `machine` field from the unmerged PR #312): the
  screens open without an error, the unknown field is dropped, and adding,
  restyling, moving, and removing fields save and survive re-navigation and
  the on-disk catalog.
- The same screens with a saved catalog that is not JSON: the red
  explanation and Reset Saved Fields on both the list and the Host page,
  editing controls disabled, the reset confirmation and its dismissal, and
  editing after the reset.
- Sync from plugin while the catalog is unreadable (no dialog, dimmed) and
  after the reset (its confirmation opens).

## Found & fixed

- **An unknown field name locked every edit.** The persisted catalog used the
  strict decoder, so one name this build did not know made the whole catalog
  unreadable and every write was refused with "could not be read", with
  nothing on screen explaining why. The catalog now loads through the same
  lenient decoder plugin snapshots use, dropping unknown names and invalid
  colors individually; structural damage still keeps the bytes and refuses
  writes, and both screens announce that state with a Reset Saved Fields
  action (`Sources/Heeler/Console/AgentRowLayout.swift`,
  `Sources/Heeler/Console/AgentRowLayoutStore.swift`,
  `Sources/Heeler/Settings/AgentLayoutErrorView.swift`).
- **A refused add left a phantom chip on the row.** Adding a field against an
  unreadable catalog reused the draft-session rule that a failed save keeps
  its drafts, so Row 3 showed the unsaved field as if saved and the add sheet
  stayed open. An inline commit now discards its draft on a refused save, the
  sheet closes so the message is visible, and while the catalog is unreadable
  the chips, add chips, and Sync from plugin are disabled
  (`Sources/Heeler/Settings/AgentListFieldsEditor.swift`,
  `Sources/Heeler/Settings/AgentListFieldsSettingsView.swift`,
  `Sources/Heeler/Settings/AgentListFieldsAddFieldSheet.swift`).
- **Disabled Sync from plugin still looked enabled.** Its label forced the
  tint color over the disabled dimming; it now picks the tertiary style while
  the catalog is unreadable (`AgentListFieldsSettingsView.swift`).

## Still open

- Persistence across an app relaunch was checked by the driver reading the
  on-disk catalog, not through the GUI.
- On this iOS version an anchored confirmation dialog renders as a popover
  without a Cancel button; tapping outside cancels. Plans should not expect a
  Cancel button.
- Driving this Simulator while another testloop drives a second one only
  works with device-scoped `simctl`/`idb` commands, which the Codex sandbox
  blocks; the authorization has to be stated in the chat pointer, not only in
  the prompt file. `project.md` records the seeding and driving lessons.
