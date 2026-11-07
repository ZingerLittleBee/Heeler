# Heeler iPad App Store mockups

Nine landscape exports for the 13-inch iPad screenshot slot. Each export is
an opaque RGB PNG at 2752 × 2064 pixels. The numbered filenames define the proposed
upload order, with the floating-window presentation first.

## Contents

| Order | Export | Focus |
| --- | --- | --- |
| 1 | `exports/01-fits-your-workspace.png` | A real floating Heeler window on iPad |
| 2 | `exports/01a-herdr-desktop-too.png` | A herdr-core Host beside Herdr TUI Hosts, and its spaces in the sidebar |
| 3 | `exports/01b-just-say-it.png` | Voice Input: the recording bar, then the transcribed draft |
| 4 | `exports/02-every-agent-one-console.png` | Agent sidebar and a selected Claude Code conversation |
| 5 | `exports/03-type-directly-stay-in-flow.png` | Direct Input with its shortcut row and the iOS keyboard |
| 6 | `exports/04-see-what-changed.png` | Changes for an Agent's Checkout beside the Agent sidebar |
| 7 | `exports/05-every-change-line-by-line.png` | A file's side-by-side diff with edited words marked |
| 8 | `exports/06-skills-within-reach.png` | Skills in the Direct Input tools keyboard |
| 9 | `exports/07-a-shell-when-you-need-one.png` | Terminals sidebar and a Shell Terminal in Keys mode |

`../desktop/compose_desktop.py` renders the Herdr desktop export and
`../voice/compose_voice.py` the Voice Input export; their sources are in
`../desktop/` and `../voice/`. `compose_mockups.py` renders the other seven,
and only those seven appear in `manifest.json`, `contact-sheet.jpg` and
`index.html`. Neither the contact sheet nor the source captures belong in the
upload set. The locally generated `../ipad-13-app-store.zip` contains only the
exports and is excluded from Git.

## Source preservation

- The sources are real captures from the iPad Pro 13-inch (M5) (16GB) simulator
  on iOS 27.0, UDID `A993BBE0-BD87-4807-8541-34A23C15C6A9`, taken on 2026-11-01.
  The app connected over SSH to an isolated herdr backend on this Mac
  (`scripts/isolated-herdr-backend.py`), not demo fixtures. Claude Code and Codex
  ran real sessions on small demo repositories, so the conversations, approval
  prompt, Changes, diffs, Skills, and shell output are their real output.
- The same captures are copied to `docs/images/*-ipad.png` for the README and to
  `landing/src/assets/screens/*-ipad.png` for the landing page.
- Source captures are copied unchanged. The renderer scales each 4:3 capture
  uniformly to 2112 × 1584, with a small rounded corner mask. It does not redraw,
  rearrange, stretch, or replace any application content.
- The generated background is shared with `../iphone-6.9/assets/background.png`.
  Headlines, subheads, frame, and shadow are deterministic compositions adapted
  from the existing iPhone renderer and the approved iPad HTML preview.
- Source and export SHA-256 values, copy, geometry, and format are recorded in
  `manifest.json`.

The English marketing copy follows the existing App Store set. Additional
localized variants have not been produced.

## Scope and verification

All seven rendered PNGs and the contact sheet were visually inspected. The
renderer checks source dimensions, equal scale on both axes, headline and
subhead safe areas, and output dimensions/color mode. An independent `sips`
check confirmed 2752 × 2064 and `hasAlpha: no` for every export. No App Store
Connect upload or product-page preview was performed.

## Regenerate

From the repository root, with Pillow installed:

```sh
python3 output/app-store/ipad-13/compose_mockups.py
sips -g pixelWidth -g pixelHeight -g hasAlpha output/app-store/ipad-13/exports/*.png
ditto -c -k --norsrc --keepParent output/app-store/ipad-13/exports output/app-store/ipad-13-app-store.zip
```

The renderer uses the system SF fonts on macOS. No application build or test is
needed to regenerate these marketing assets.
