# Agent title Rename UI prototype

This draft preserves the reviewed UI as a throwaway prototype. It is not a production title-renaming implementation and is not ready to merge.

## Reviewed interaction

- Preserve the existing native More menu and append one `Rename` item.
- Add `Rename` after `Pin` in the Agent list's native context menu.
- Both entries open the same sheet: the current title in an editable field, `Generate Automatically`, `Cancel`, and `Save`.
- Keep generation inside the sheet, rather than adding a separate generation item to either menu.

The earlier replacement of More with a confirmation dialog was rejected. `AgentDetailHeader` and its native menu styling remain unchanged.

## Run

From the repository root, select an isolated simulator UUID using `make simulator-ui`, then run:

```sh
make -f docs/prototypes/title-rename/Makefile preview SIMULATOR_UDID=<uuid>
```

Long-press the Product Docs row and choose Rename. To review the other entry, open that row's Chat and tap the upper-right More icon.

`--demo-title-prototype` requires `--demo-screenshots`. `--demo-title-list` starts on the list; omitting it opens the Product Docs Chat. All prototype views and state are compiled only in Debug Simulator builds. Normal app launches and Release/device builds retain their existing behavior. The existing Agent alias rename remains separate and unchanged.

## Behavior limits

The title field uses local view state. Generate substitutes the deterministic fixture title `Update the setup guide`; it does not call an Agent or a model. Save dismisses the sheet without persisting a title. These actions must not be interpreted as working title synchronization.

Production work remains: per-Agent session-title discovery, supported rename/generation commands, safe delivery to the same idle session, result reconciliation, error handling, unsupported-Agent presentation, and behavior tests. The UI preview does not establish that every Agent supports automatic generation.

## Visual evidence

The screenshots use demo data on an iPhone 17 Pro simulator running iOS 27.0, with light appearance and the default text size. The native menus were opened through actual CUA input, and captured with the repository's simulator screenshot helper. The screenshots establish Simulator UI behavior only; no physical-device or remote Agent acceptance was performed.

- [Native More menu](screenshots/more-menu.png)
- [Agent list context menu](screenshots/list-menu.png)
- [Shared Rename sheet](screenshots/rename-sheet.png)
