# Heeler App Store creative assets

The two still images for the "Header and Search Results" tab of an App Store
version in App Store Connect, introduced with iOS 27. They are uploaded in the
App Store Connect web UI.

| Slot | Export | Focus |
| --- | --- | --- |
| Header | `exports/product-page-header-3840x1646.png` | "Your Agents. Anywhere." over the iPhone Changes, Console, and live terminal, fanned out |
| Search Results | `exports/search-results-3840x2560.png` | "Every Agent. One Console." beside the iPhone Console in front of Changes |

Both exports are opaque RGB PNGs (no alpha channel), at the 21:9 header size
and the largest 3:2 search results size from Apple's
[creative asset specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications/).
The header claim differs from the first screenshot's headline, which appears
on the same product page.

## Composition

The layouts follow the samples on Apple's
[asset best practices](https://developer.apple.com/app-store/asset-best-practices/)
page: the art fills the canvas instead of floating in empty background. The
direction ("Paper and one accent") was picked from five options explored in
Claude Design: warm off-white paper, dark copy with its second line in the
brand purple, and a faint purple glow rising from the bottom edge.

- The product page shows the header as a short strip, so a dense device
  screenshot reads as clutter. As in Apple's samples, one large claim fills the
  safe area; three iPhones fan out below it inside the width an iPhone shows
  and run past the bottom edge, so narrower crops may cut them but never the
  claim.
- The search card shows the whole 3:2 image. As in Apple's Forest Explorer and
  Airline samples, a large claim sits on the left and two overlapping, tilted
  iPhones on the right, running past the bottom edge.

## Safe and layout areas

Apple publishes the art safe areas only in its creative asset templates. The
values below come from the "Art Safe Area" layer of
`creative_assets-templates.sketch`:

| Canvas | Safe area origin | Safe area size |
| --- | --- | --- |
| 3840 × 1646 header | 1097, 493 | 1646 × 661 |
| 3840 × 2560 search result | 836, 765 | 2168 × 1030 |

The renderer fails if any text leaves an asset's layout area, if a device does
not begin on the canvas, or if a device's rotated bounds cover the copy. The
header's layout area is its safe area, because the header is cropped
differently on each device. The search card's
layout area is the canvas less a margin (260, 220, 3320 × 2120), because Apple's
own search result samples fill the card well past the template's safe area.

## Source preservation

- `sources/changes-iphone.png` and `sources/live-terminal-iphone.png` are iPhone
  18 Pro simulator captures of a real Claude Code session on a throwaway demo
  repository, through the isolated herdr backend. `docs/images/console-iphone.png`
  supplies the Console. Captures are scaled uniformly, masked with rounded
  corners, and rotated as whole devices; no application content is redrawn,
  rearranged, or stretched.
- The paper background, dark device bezels, shadows, and copy are drawn by the
  renderer with Pillow, matching the geometry of the chosen Claude Design
  option at full size.
- Geometry and export SHA-256 values are recorded in `manifest.json`.

## Regenerate

```sh
python3 output/app-store/creative-assets/compose_creative.py
```

Pass `--review <dir>` to also write reduced copies with the safe area outlined
in red and the layout area in cyan. The header copy also marks, in yellow, a
community measurement of the iPhone product page crop (x 330 to 3530), which
matches App Store Connect's device preview; it is not an Apple specification.
