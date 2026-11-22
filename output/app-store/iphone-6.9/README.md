# Heeler iPhone App Store screenshots

These exports preserve the exact application UI from the committed iPhone
captures and add deterministic marketing copy over the landing page's graphite.
The order follows the iPhone screens on the landing page.

## Exports

| Order | Export | Source | Copy |
| --- | --- | --- | --- |
| 1 | `exports/01-every-agent-one-console.png` | `sources/console-iphone.png` | Every Agent. One Console. |
| 2 | `exports/01a-herdr-tmux-rex.png` | `../servers/sources/iphone-*.png` | Herdr, tmux or Rex. |
| 3 | `exports/01b-just-say-it.png` | `../voice/sources/iphone-*.png` | Just Say It. |
| 4 | `exports/02-type-directly-stay-in-flow.png` | `sources/live-terminal-iphone.png` | Type Directly. Stay in Flow. |
| 5 | `exports/03-every-reply-as-a-chat.png` | `sources/chat-iphone.png` | Every Reply. As a Chat. |
| 6 | `exports/04-control-without-leaving-the-flow.png` | `sources/agent-iphone.png` | Control Without Leaving the Flow |
| 7 | `exports/05-see-what-changed.png` | `sources/changes-iphone.png` | See What Changed. |
| 8 | `exports/06-your-shell-within-reach.png` | `sources/terminal-iphone.png` | Your Shell. Within Reach. |
| 9 | `exports/07-skills-without-breaking-flow.png` | `sources/skills-iphone.png` | Skills Without Breaking Flow |
| 10 | `exports/09-your-agents-at-a-glance.png` | `sources/live-activity-iphone.png` | Your Agents. At a Glance. |

All files are opaque 1320×2868 PNGs for the iPhone 6.9-inch App Store slot.
`../servers/compose_servers.py` renders the Servers image (order 2) and
`../voice/compose_voice.py` the Voice Input image (order 3); this directory's
`compose_mockups.py` renders the rest. It reads a capture from `sources/` first
and falls back to the README image of the same name in `docs/images/`.
The iPad set is `../ipad-13/`.

`sources/live-activity-iphone.png` carries the display mask like the other
sources. `docs/images/live-activity-iphone.png`, which the landing page also
uses, is a second capture of the same Lock Screen taken with `--mask=ignored`,
so its corners are square, as a device screenshot's are.

## Provenance

`../backdrop.py` draws the background: the landing page's neutral graphite, a
little lighter toward the top edge, with a faint light in each image's accent
behind the top of the screenshot. It replaced a texture from OpenAI image
generation in 0.1.21, so nothing in these exports comes from a generative
model. All UI, headlines, subheads, borders, masks, and sizing are composed
locally by compose_mockups.py.

## Regenerate

Run from the repository root with Pillow and NumPy installed:

```sh
python3 output/app-store/iphone-6.9/compose_mockups.py
```
