# App Store listing copy

`promo.txt`, `keywords.txt`, and `description.txt` hold draft `en-US` App Store
Connect listing text for `scripts/store-shots.py asc`:

| File | App Store Connect field | Limit (UTF-16 code units) |
| --- | --- | --- |
| `promo.txt` | `promotionalText` | 170 |
| `keywords.txt` | `keywords` | 100 |
| `description.txt` | `description` | 4000 |

These files match the listing uploaded for 0.1.21, which names Herdr TUI, the
Herdr desktop app, tmux and Rex side by side. Compare them against the live App
Store Connect listing before any upload, so store edits made since are not
overwritten.

`python3 scripts/test-store-shots.py` checks these character limits so edits
fail locally before an App Store Connect upload is tried. To preview or apply an
upload when the user asks to update the store listing, follow
`docs/agents/store-screenshots.md`.
