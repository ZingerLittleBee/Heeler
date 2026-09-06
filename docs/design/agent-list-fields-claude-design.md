# Agent List Fields: Claude Design redesign

Status: Design only, proposed for review
Date: 2026-09-06
Issue: [#281](https://github.com/zingerbee/Heeler/issues/281)
Scope: interaction design for the Settings screen `AgentListFieldsSettingsView`. No Swift, store, transport, test, or project changes are part of this document.

## Provenance

- Tool: the Claude Design web app, driven by Claude through the user's signed-in browser session. The `claude_design` MCP could not be authorized from Claude Code 2.1.261, so the design was produced in the product's own editor.
- Project: <https://claude.ai/design/p/365934e6-2d44-44a0-8248-6790784db71d> (private, owner's account, title "Agent List Fields", file `Agent List Fields.dc.html`). Sharing settings were not changed.
- Inputs: the brief in [`agent-list-fields-claude-design/brief.md`](agent-list-fields-claude-design/brief.md) plus the four simulator screenshots of the current implementation. Design system: None. Model: Opus 5, High.
- Export: [`agent-list-fields-claude-design/agent-list-fields.dc.html`](agent-list-fields-claude-design/agent-list-fields.dc.html) is the prototype's source as served by Claude Design, with only the editor-injected runtime block removed. It is a Claude Design component file (`x-dc`, `sc-if`, `sc-for`, `x-import ./ios-frame.jsx`, `./support.js`) and does not run standalone; open the project link to interact with it. It carries no credentials.
- Verification: every one of the 20 states in the prototype's state switcher was selected programmatically inside the served prototype and its rendered text captured; the in-frame Host header, Edit, and Cancel controls were exercised the same way. The live editor window could not be screenshotted during that pass, so this document has no images of the finished prototype; reviewers should open the project link.

## Why redesign

The current screen makes every edit a swipe: Move Up, Move Down, and Delete hide behind leading and trailing swipe actions on each row, overrides are typed into a bare text field, and the Sync result is a footer sentence. Rows show raw token names, so the user cannot tell what an Agent will look like without saving. The redesign keeps the established behavior contract and replaces swipe-only editing with standard iOS list editing, adds a rendered Console preview per Host, and reports Sync and dirty state inline where the user is looking.

## Final interaction

### Read-only (default)

- Large-title screen "Agent List Fields" with a one-line intro: "Each Host decides which fields appear on its Agent rows in Console. Tap Edit to change them." Top-right "Edit".
- One inset-grouped section per Host, all collapsed on open. The header shows the Host name, a caption ("Following herdr plugin" or "Your fields"), and a chevron. The header is a single button with an accessibility label such as "Studio Mac, following herdr plugin, collapsed".
- Expanding a Host shows, in order: a "Console preview" block rendering one sample Agent row exactly as the Console will draw it from the current rows (sample data: workspace "heeler", agent "claude", title "fix sidebar sync"); the row list ("Row 1", "Row 2", …) where each row shows its fields as small monospace chips in render order and a chevron; an "Agent overrides" group listing per-kind overrides or "No overrides. Every Agent uses the rows above."
- Tapping a row pushes the Field Editor in read-only form. No handles, no minus controls, no Add buttons, no Sync button outside edit mode.
- A Host with zero rows shows a "Status only" preview and "No rows. Agents show only their status." With no Hosts at all, the screen shows a `ContentUnavailableView`-style "No Hosts" with "Add a Host to configure its Agent rows."

### Edit session

- "Edit" swaps the bar to "Cancel" (left) and a filled blue checkmark (right, accessibility label "Save changes"). The intro changes to "Changes stay in a draft until you tap the checkmark. Sync fills one Host's draft without saving it." Expansion state is kept.
- Rows gain a reorder handle on the trailing edge and a red minus on the leading edge. Rows stay tappable to open the Field Editor. "Add Row" appends an empty row ("No fields yet") at the end of that Host's list.
- Delete is two-step in place: the minus arms the row and reveals a red "Delete" button on that row; tapping elsewhere disarms. No swipe is required for any action, and every action is a button for VoiceOver.
- Reorder: dragging the handle lifts the row and dims the others; dropping commits the new order and marks the Host dirty.
- "Add Override" opens a menu of Agent kinds seen on that Host (for example claude, codex, grok) plus "Other…" for free text. A new override is its own collapsible sub-block under "Agent overrides", seeded from the Host's rows, with the same row list, handles, minus, and Add Row. Its minus reveals an in-place "Remove" confirmation.
- "Sync from plugin" sits under each Host's rows in edit mode. States: idle button; pending ("Syncing…" with a spinner, and the rest of that Host's controls disabled); success ("Filled from plugin. Unsaved until you save."); failure in red with a "Retry" link ("Couldn't reach Studio Mac. Draft unchanged." or "You're offline. Draft unchanged."). Sync never persists.
- Dirty state: the title gains an orange "Unsaved changes" subtitle and each changed Host header shows an orange dot. Hosts never share drafts; Build Server stays clean while Studio Mac is dirty.
- Cancel with a dirty draft shows a confirmation dialog "Discard changes?" / "Your unsaved rows will be lost." with destructive "Discard Changes" and "Keep Editing". Cancel with a clean draft exits immediately.
- The checkmark saves every dirty Host, returns to read-only, shows a brief green "Saved" subtitle, and flips saved Hosts' captions to "Your fields".

### Field Editor (pushed screen)

- Title "Row N", subtitle with the Host name and, for overrides, "· claude override". Back returns to the Settings screen with the Host still expanded.
- Section "Fields in this row": one row per field with its key in monospace, a one-line description ("Workspace or repo folder name"), and a style control (Default, Secondary, Monospace) shown as a menu. In edit mode fields also get a red minus and a reorder handle.
- "Add Field" opens a sheet "Fields reported by <Host>" listing only fields not yet in the row, each with its description. Picking one appends it with the Default style and closes the sheet.
- Footer: "Fields render left to right in this row. Changes stay in the draft until you save on the previous screen."

### iPad and accessibility

- iPad uses the same structure in a wider column; inset grouped lists are capped at a readable width (about 640pt) and centred.
- All edit actions are buttons. Field chips carry labels such as "Field 1 of 2: workspace, default style". Text uses system styles so Dynamic Type applies.

## State coverage

The prototype's state switcher jumps to each state; the table records what each renders, as captured from the served prototype.

| # | State | Rendered result |
| --- | --- | --- |
| 1 | Read-only, collapsed | Both Hosts collapsed; captions "Following herdr plugin" / "Your fields"; Edit in the bar |
| 2 | Read-only, expanded | Console preview, Row 1 (workspace, agent), Row 2 (terminal_title), "No overrides" |
| 3 | Edit mode | Cancel and checkmark; Add Row, Add Override, Sync from plugin appear |
| 4 | Reorder in progress | Rows swapped, lifted row highlighted, "Unsaved changes" subtitle |
| 5 | Delete row | Armed row shows in-place Delete |
| 6 | Add row | "Row 3 · No fields yet" appended, dirty |
| 7 | Add override menu | Menu "Agent kinds seen on this Host": claude, codex, grok, Other… |
| 8 | Override added | "claude · 2 rows" sub-block with its own rows and Add Row |
| 9 | Remove override | Override armed, in-place Remove |
| 10 | Sync pending | "Syncing…", Add Row hidden, Host controls disabled |
| 11 | Sync success | Rows replaced by plugin rows (adds branch), "Filled from plugin. Unsaved until you save." |
| 12 | Sync failure | Red "Couldn't reach Studio Mac. Draft unchanged." with Retry |
| 13 | Offline | Red "You're offline. Draft unchanged." with Retry |
| 14 | Unsaved changes | Orange subtitle and Host dot after adding a field |
| 15 | Cancel confirmation | "Discard changes?" dialog with Discard Changes / Keep Editing |
| 16 | Saved | Read-only, green "Saved" subtitle, Studio Mac caption now "Your fields" |
| 17 | Empty rows | Build Server with "Status only" preview and "No rows…" plus Add Row |
| 18 | No Hosts | "No Hosts" content-unavailable message |
| 19 | Field Editor | Row 1 of Studio Mac: workspace (Default), agent (Secondary), Add Field |
| 20 | Add Field sheet | Sheet listing terminal_title, branch, cwd, host with descriptions |

Live controls verified in addition to the switcher: tapping a Host header expands it, Edit enters the session, and Cancel on a clean draft exits without a dialog.

## Native implementation guidance

This is guidance for a later, separately requested implementation unit. The data model and `AgentListFieldsEditor` API need no change.

- Keep `AgentListFieldsEditor` as the draft owner: `beginEditing`, `cancel`, `save`, `update(_:_:)`, `setRows(_:kind:for:)`, `syncFromPlugin(_:)`, `hasUnsavedChanges`, `syncStates`, and `source(for:)` already express every state above. Per-Host dirty dots need one addition: compare each Host's draft with its baseline, which the editor can expose as a computed set.
- Use one `List` with `.environment(\.editMode, .constant(isEditing ? .active : .inactive))` on the List itself so `.onMove` and `.onDelete` render native handles and minus controls. The earlier trap (edit mode applied only to embedded row content disabled `NavigationLink`s) is avoided by opening the Field Editor with a `Button` plus `navigationDestination(item:)` instead of `NavigationLink`, and by marking non-row items (Host headers, previews, Add buttons, Sync) `.moveDisabled(true)` and `.deleteDisabled(true)`.
- Model each Host as a `Section` whose header is a `Button` toggling expansion, with content shown only when expanded. Overrides are nested `Section`s within the Host's group, or a `DisclosureGroup` when the flatter hierarchy reads better on iPhone.
- Two-step delete: SwiftUI's native minus already reveals a Delete button in place, which is the intended behavior. Do not add swipe actions; keep `accessibilityAction`s for move and delete so VoiceOver has explicit verbs.
- Add Override: a `Menu` listing kinds from that Host's Agent Inventory (`ConsoleStore`) minus kinds already overridden, plus "Other…" presenting an alert with a text field validated by `agent.rename`'s name rule.
- Sync: render `SyncState` under the Host's rows with `ProgressView` for pending, a secondary caption for success, and a red caption plus "Retry" for failure. Disable that Host's controls while pending. Keep `settings.agentList.sync.<hostID>` and `settings.agentList.syncTip.<hostID>` identifiers.
- Title subtitle: iOS has no navigation subtitle API on `.inline` titles, so render "Unsaved changes" / "Saved" as a caption directly under the large title inside the first list section, tinted orange or green.
- Cancel confirmation: `confirmationDialog` with a destructive "Discard Changes" role; keep `settings.agentList.cancel`, `.edit`, `.save`, `.error`, and `.host.<hostID>` identifiers so existing tests continue to locate controls.
- Console preview: reuse the Console row view with sample values per token so the preview and the real list cannot drift.
- Empty states: `ContentUnavailableView` for "No Hosts"; a plain caption row for a Host with no rows.
- Field Editor: a pushed `List` in the same edit mode with `.onMove`/`.onDelete`, a `Menu` for style, and a `.sheet` for Add Field that lists `AgentRowToken` cases not yet present in the row.

## Limitations

- The prototype's reorder is a tap-to-move stand-in (the handle moves the row one position); the native implementation should use real drag reordering.
- The exported `.dc.html` depends on Claude Design's runtime (`support.js`, `ios-frame.jsx`) and only renders inside the project. No standalone HTML, PDF, or image export was available from the product for this file type.
- No screenshots of the finished prototype could be captured in this session; the project link is the visual reference.
- The field list (workspace, terminal_title, agent, branch, cwd, host) and the "kinds seen on this Host" list are illustrative sample data, not the app's `AgentRowToken` set.
- iPad and Dynamic Type are described, not rendered, and nothing was run on a device or simulator.
- "Other…" custom override naming is modeled as a free-text sub-block; validation and duplicate handling are left to the implementation.
