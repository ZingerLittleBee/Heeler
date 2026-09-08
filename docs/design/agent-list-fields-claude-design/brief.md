# Brief sent to Claude Design

Verbatim prompt submitted on 2026-09-06 with the four reference screenshots of the current implementation (read-only, edit, swipe, saved) attached. Design system: None. Model: Opus 5, High.

> Design an interactive iPhone prototype (iOS 18, native SwiftUI look: large-title navigation bar, inset grouped lists, SF Pro, system blue tint, light mode) for one Settings screen of Heeler, a native iOS companion app for the herdr agent console. The screen is called "Agent List Fields". It decides which text fields (workspace, terminal title, agent kind, branch, cwd, and similar) appear on each Agent row in the app's Console list, one row layout per Host. A Host is a remote machine running herdr. This is a settings page, not a dashboard and not a web landing page. Keep it calm and native; avoid cards inside cards, gradients, badges, and decorative icons.
>
> The four attached screenshots show the CURRENT implementation. Keep the existing behavior contract but reconsider the interaction as a whole, with less clutter and less swipe-only discovery.
>
> Rules that must hold:
> 1. Read-only by default. The top-right "Edit" button opens one draft editing session for the whole screen. While editing, the bar shows "Cancel" (left) and a blue checkmark (right). Only the checkmark saves. Cancel discards; if there are unsaved changes, show a native confirmation dialog "Discard changes?" with a destructive "Discard Changes" and "Keep Editing".
> 2. Each Host is an independent, collapsible section. Every Host is collapsed when the screen opens. Expanding a Host shows its actual rows directly under the header. There is no "Default Rows" label or sub-screen, no global layout section, no "Extra spacing" or row-gap control, and no visible internal fallback preset.
> 3. A Host without a saved layout follows its herdr plugin's fields (caption: "Following herdr plugin"). A Host with a saved layout shows caption "Your fields".
> 4. Each Host has a "Sync from plugin" action that fetches that Host's plugin fields and fills the draft. It shows a pending state, then success or failure feedback inline, and never saves by itself.
> 5. Per-Agent-kind overrides (for example a separate row layout just for "claude" or "codex") exist per Host and can be added and removed. Hosts never share state.
> 6. Rows have a meaningful preview and a field editor entry.
>
> Chosen interaction, please build exactly this:
> - Host header: Host name, caption ("Following herdr plugin" or "Your fields"), and a chevron. When expanded, the first thing under the header is a sample Agent row rendered the way the Console will show it (example data: workspace "heeler", title "fix sidebar sync", agent "claude"), so the user sees the result, not tokens.
> - Row list: one list row per layout row. Each shows its fields as small monospace chips in order (workspace, terminal_title, agent) with a right chevron. Tapping a row opens the Field Editor (a pushed screen: the row's fields as a reorderable list with a red minus, a picker sheet "Add Field" listing the available fields with a short description each, and per-field style: Default, Secondary, Monospace).
> - Edit mode on the main screen: rows show native reorder handles and a red minus delete control (standard iOS list editing), plus a blue "+ Add Row" at the end of the row list. Rows stay tappable to open the Field Editor while editing.
> - Overrides: below the rows, a group "Agent overrides". Each existing override (e.g. "claude") is its own collapsible sub-block with the same row list. In edit mode, a blue "+ Add Override" opens a menu of Agent kinds seen on that Host (claude, codex, grok) plus "Other…" for free text. An override has a red minus in edit mode to remove it.
> - Sync: in edit mode, under the rows, a blue "Sync from plugin" button per Host. States: idle; pending (spinner, "Syncing…", other controls of that Host disabled); success ("Filled from plugin. Unsaved until you save."); failure (red text "Couldn't reach Studio Mac. Draft unchanged." with a "Retry" link); offline variant ("You're offline.").
> - Unsaved: while dirty, the navigation title shows a small subtitle "Unsaved changes" and the Host header of each changed Host shows a small orange dot. After saving, a brief "Saved" caption appears and captions flip to "Your fields".
> - Empty rows: a Host with zero rows shows "No rows. Agents show only their status." and "+ Add Row" in edit mode. Empty Hosts: the screen shows a ContentUnavailableView-style message "No Hosts" with "Add a Host to configure its Agent rows."
> - iPad: same layout in a wider column; note in the prototype that lists get a readable max width. Accessibility: all edit actions are buttons (no swipe-only actions), Dynamic Type friendly, VoiceOver labels on chips.
>
> Deliverable: one interactive prototype inside an iPhone 15 Pro frame with a small state switcher outside the frame that jumps to these states: 1 read-only collapsed, 2 read-only expanded, 3 edit mode, 4 reorder in progress, 5 delete row, 6 add row, 7 add override menu, 8 override added, 9 remove override, 10 sync pending, 11 sync success, 12 sync failure, 13 offline, 14 unsaved changes, 15 cancel confirmation, 16 saved, 17 empty rows, 18 no Hosts, 19 Field Editor, 20 Add Field sheet. Make the in-frame controls actually work where practical (expand/collapse, Edit/Cancel/checkmark, opening the Field Editor). Use two Hosts: "Studio Mac" and "Build Server".

## Correction pass

Verbatim follow-up prompt submitted in the same project after review, asking for one focused correction. The export in this directory is the source served after this pass.

> One focused correction pass on the existing prototype. Keep every one of the 20 states, all copy, layout, and the state switcher exactly as they are. Fix only these four defects in Agent List Fields.dc.html:
>
> 1. Add Row is dead. The template binds host.addRow and ov.addRow but renderVals() never defines them. Implement both: append an empty row ({ fields: [] }, unique id) to that Host's rows or to that override's rows, so the draft becomes dirty, the Console preview and row list update, the checkmark saves it, and Discard removes it again.
>
> 2. Overrides need stable identity independent of their display name. Give every override an internal id (for example a counter) and use that id, never the kind string, for bag() lookups, armed state, remove, rename, and row operations. For "Other…", do not create an override with an empty name: show an inline text field with an Add button, trim the input, reject empty and duplicate kinds (case-insensitive) with a short hint, and only then create the override. No name grammar beyond trim and non-duplicate. Row operations inside an unnamed or renamed override must never touch the Host's own rows.
>
> 3. The Field Editor must be truly read-only outside an edit session. When editing is false: hide the red minus, reorder handle, style menu, and Add Field; show the style as plain text; make row.open still work; guard every mutation handler (remove, move, style pick, add field) so it is a no-op when not editing; footer reads "Tap Edit on the previous screen to change fields." States 19 and 20 stay as they are (editing).
>
> 4. Dirty tracking must ignore presentation state: expanding or collapsing an override sub-block must not mark the Host dirty, so keep the expanded flag out of the baseline comparison. Also render the orange "Unsaved changes on this Host" dot only when that Host is dirty, and do not render an aria-labelled element at all for a clean Host.
>
> Do not change anything else.
