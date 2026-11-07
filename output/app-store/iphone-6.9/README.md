# Heeler iPhone App Store screenshots

These exports preserve the exact application UI from the committed iPhone
captures and add deterministic marketing copy over a generated background. The
order follows the iPhone screens on the landing page.

## Exports

| Order | Export | Source | Copy |
| --- | --- | --- | --- |
| 1 | `exports/01-every-agent-one-console.png` | `sources/console-iphone.png` | Every Agent. One Console. |
| 2 | `exports/01a-herdr-desktop-too.png` | `../desktop/sources/iphone-*.png` | Herdr Desktop, Too. |
| 3 | `exports/01b-just-say-it.png` | `../voice/sources/iphone-*.png` | Just Say It. |
| 4 | `exports/02-type-directly-stay-in-flow.png` | `sources/live-terminal-iphone.png` | Type Directly. Stay in Flow. |
| 5 | `exports/03-every-reply-as-a-chat.png` | `sources/chat-iphone.png` | Every Reply. As a Chat. |
| 6 | `exports/04-control-without-leaving-the-flow.png` | `sources/agent-iphone.png` | Control Without Leaving the Flow |
| 7 | `exports/05-see-what-changed.png` | `sources/changes-iphone.png` | See What Changed. |
| 8 | `exports/06-your-shell-within-reach.png` | `sources/terminal-iphone.png` | Your Shell. Within Reach. |
| 9 | `exports/07-skills-without-breaking-flow.png` | `sources/skills-iphone.png` | Skills Without Breaking Flow |
| 10 | `exports/09-your-agents-at-a-glance.png` | `docs/images/live-activity-iphone.png` | Your Agents. At a Glance. |

All files are opaque 1320×2868 PNGs for the iPhone 6.9-inch App Store slot.
`../desktop/compose_desktop.py` renders the Herdr desktop image (order 2) and
`../voice/compose_voice.py` the Voice Input image (order 3); this directory's
`compose_mockups.py` renders the rest. It reads a capture from `sources/` first
and falls back to the README image of the same name in `docs/images/`.
The iPad set is `../ipad-13/`.

## Provenance

The background was generated with OpenAI image generation as an abstract,
text-free dark terminal texture. All UI, headlines, subheads, borders, masks,
and sizing are composed locally by compose_mockups.py; the source screenshots
are never redrawn by a generative model.

## Regenerate

Run from the repository root with Pillow installed:

```sh
python3 output/app-store/iphone-6.9/compose_mockups.py
```
