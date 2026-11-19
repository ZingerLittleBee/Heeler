# Servers App Store screenshot

`compose_servers.py` renders "Herdr, tmux or Rex." as the second image of all
three screenshot slots:

| Slot | Export | Size |
| --- | --- | --- |
| iPhone 6.9-inch | `../iphone-6.9/exports/01a-herdr-tmux-rex.png` | 1320 × 2868 |
| iPad 13-inch | `../ipad-13/exports/01a-herdr-tmux-rex.png` | 2752 × 2064 |
| iPhone Duo | `../iphone-duo/exports/01a-herdr-tmux-rex.png` | 2853 × 2007 |

Each image pairs the Hosts list's row for one machine, which carries a tag per
Server, with that Host's Servers section, where Herdr TUI, herdr-core, tmux and
Rex each have a switch. Pieces are cropped and scaled, never repainted.

## Sources

`sources/` holds two unedited captures per device, taken on 2026-11-20 from the
iPhone 17 Pro Max and iPad Pro 13-inch (M5) simulators, running a development
build of 0.1.21.

- `*-hosts.png` shows the Hosts list.
- `*-host.png` shows the Host page of Studio Mac.

The iPhone Duo image is composed from the iPhone captures. Folded, the Duo lays
these pages out as an iPhone does; no capture was taken on the Duo simulator.

Studio Mac is one sshd on this Mac in front of four isolated servers, as
[the runbook](../../../docs/agents/store-screenshots.md#servers) describes. No
Agent runs on any of them.

## Regenerate

From the repository root, with Pillow and NumPy installed:

```sh
python3 output/app-store/servers/compose_servers.py
```
