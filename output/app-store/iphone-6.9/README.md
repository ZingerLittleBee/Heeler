# Heeler iPhone App Store screenshots

These exports preserve the exact application UI from the committed iPhone
captures and add deterministic marketing copy over a generated background. The
order follows the iPhone screens on the landing page.

## Exports

| Order | Export | Source | Copy |
| --- | --- | --- | --- |
| 1 | `exports/01-every-agent-one-console.png` | `docs/images/console-iphone.png` | Every Agent. One Console. |
| 2 | `exports/02-type-directly-stay-in-flow.png` | `docs/images/live-terminal-iphone.png` | Type Directly. Stay in Flow. |
| 3 | `exports/03-every-reply-as-a-chat.png` | `docs/images/chat-iphone.png` | Every Reply. As a Chat. |
| 4 | `exports/04-control-without-leaving-the-flow.png` | `docs/images/agent-iphone.png` | Control Without Leaving the Flow |
| 5 | `exports/05-see-what-changed.png` | `docs/images/changes-iphone.png` | See What Changed. |
| 6 | `exports/06-your-shell-within-reach.png` | `docs/images/terminal-iphone.png` | Your Shell. Within Reach. |
| 7 | `exports/07-skills-without-breaking-flow.png` | `docs/images/skills-iphone.png` | Skills Without Breaking Flow |
| 8 | `exports/08-every-host-in-view.png` | `docs/images/hosts-iphone.png` | Every Host. In View. |
| 9 | `exports/09-your-agents-at-a-glance.png` | `docs/images/live-activity-iphone.png` | Your Agents. At a Glance. |

All files are opaque 1320×2868 PNGs for the iPhone 6.9-inch App Store slot.
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
