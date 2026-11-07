# Herdr desktop App Store screenshot

`compose_desktop.py` renders "Herdr Desktop, Too." as the second image of all
three screenshot slots:

| Slot | Export | Size |
| --- | --- | --- |
| iPhone 6.9-inch | `../iphone-6.9/exports/01a-herdr-desktop-too.png` | 1320 × 2868 |
| iPad 13-inch | `../ipad-13/exports/01a-herdr-desktop-too.png` | 2752 × 2064 |
| iPhone Duo | `../iphone-duo/exports/01a-herdr-desktop-too.png` | 2853 × 2007 |

Each image pairs the Hosts card, where a herdr-core Host sits beside two Herdr
TUI Hosts, with the Agents list filtered to that Host, where the desktop app's
spaces name the Agents. Pieces are cropped and scaled, never repainted.

## Sources

`sources/` holds two unedited captures per device, taken on 2026-11-07 from the
iPhone 17 Pro Max, iPad Pro 13-inch (M5) and iPhone Duo (unfolded) simulators,
running 0.1.18 (43).

- `*-hosts.png` shows the Hosts list.
- `*-agents.png` shows the Agents list filtered to Linux Desktop: Docs is
  Blocked, Storefront Done and Payments API Working.

Studio Mac and Build Server are the `scripts/store-shots.py` rig. Linux Desktop
is a throwaway Linux VM running the Herdr desktop app, with three Claude Code
Agents on the fixture repositories. All three Hosts use machine names through a
jump host, as [the runbook](../../../docs/agents/store-screenshots.md#herdr-desktop)
describes.

## Regenerate

From the repository root, with Pillow installed:

```sh
python3 output/app-store/desktop/compose_desktop.py
```
