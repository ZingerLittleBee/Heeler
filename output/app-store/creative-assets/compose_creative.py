#!/usr/bin/env python3
"""Render the App Store product page header and search results creative assets."""

from __future__ import annotations

import argparse
import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
FONT = "/System/Library/Fonts/SFNS.ttf"
PAPER = (246, 244, 239)
GLOW = (190, 168, 255)
INK = (17, 19, 38)
INK_SECONDARY = (72, 76, 104)
ACCENT = (116, 84, 214)  # oklch(0.55 0.19 290)
BEZEL = (22, 23, 30)
SHADOW = (40, 36, 90)
SUPERSAMPLE = 4


@dataclass(frozen=True)
class Box:
    x: int
    y: int
    width: int
    height: int

    @property
    def right(self) -> int:
        return self.x + self.width

    @property
    def bottom(self) -> int:
        return self.y + self.height

    def contains(self, other: "Box") -> bool:
        return (self.x <= other.x and self.y <= other.y
                and other.right <= self.right and other.bottom <= self.bottom)


@dataclass(frozen=True)
class Asset:
    slug: str
    size: tuple[int, int]
    # The "Art Safe Area" layer of Apple's creative asset templates
    # (creative_assets-templates.sketch).
    safe: Box
    # Where text must stay and devices must begin.
    layout: Box


# The header is cropped differently per device, so its key content stays in
# Apple's safe area.
HEADER = Asset("product-page-header", (3840, 1646), Box(1097, 493, 1646, 661),
               Box(1097, 493, 1646, 661))
# The search card shows the whole 3:2 image. Apple's own search result samples
# fill the card edge to edge, well past the template's safe area, so only a
# margin is kept here.
SEARCH = Asset("search-results", (3840, 2560), Box(836, 765, 2168, 1030),
               Box(260, 220, 3320, 2120))


def font(path: str, size: int, style: str) -> ImageFont.FreeTypeFont:
    result = ImageFont.truetype(path, size)
    result.set_variation_by_name(style)
    return result


def background(size: tuple[int, int]) -> Image.Image:
    """Warm paper with a faint purple glow rising from below the bottom edge."""
    width, height = size
    # The glow is an elliptical falloff (radii 60% and 50% of the canvas,
    # centered 12% below it), computed small and scaled up: smooth at any size.
    small = (width // 8, height // 8)
    mask = Image.new("L", small)
    cx, cy, rx, ry = small[0] * 0.5, small[1] * 1.12, small[0] * 0.6, small[1] * 0.5
    mask.putdata([
        round(255 * 0.38 * max(0.0, 1 - (((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2) ** 0.5))
        for y in range(small[1]) for x in range(small[0])
    ])
    glow = Image.new("RGBA", size, (*GLOW, 0))
    glow.putalpha(mask.resize(size, Image.Resampling.BICUBIC))
    return Image.alpha_composite(Image.new("RGBA", size, (*PAPER, 255)), glow)


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    """An antialiased rounded rectangle mask, drawn supersampled."""
    big = Image.new("L", (size[0] * SUPERSAMPLE, size[1] * SUPERSAMPLE))
    ImageDraw.Draw(big).rounded_rectangle((0, 0, big.width - 1, big.height - 1),
                                          radius=radius * SUPERSAMPLE, fill=255)
    return big.resize(size, Image.Resampling.LANCZOS)


@dataclass(frozen=True)
class Phone:
    source: Path
    # Outer edge of the bezel before rotation, as the CSS box in the design.
    x: int
    y: int
    width: int  # of the screen
    bezel: int
    radius: int  # of the screen
    angle: float = 0.0  # degrees, clockwise as in CSS


def place(canvas: Image.Image, phone: Phone) -> tuple[Image.Image, Box]:
    """Scale a capture uniformly into a bezel; no UI is repainted or rearranged.

    Returns the canvas and the device's bounding box after rotation.
    """
    with Image.open(phone.source) as capture:
        height = round(phone.width * capture.height / capture.width)
        screen = capture.convert("RGB").resize((phone.width, height), Image.Resampling.LANCZOS)
    outer = (phone.width + 2 * phone.bezel, height + 2 * phone.bezel)
    # Room around the device for its rotation and shadow.
    margin = 400
    tile = Image.new("RGBA", (outer[0] + 2 * margin, outer[1] + 2 * margin), (*BEZEL, 0))
    tile.paste(Image.new("RGBA", outer, (*BEZEL, 255)), (margin, margin),
               rounded_mask(outer, phone.radius + phone.bezel))
    tile.paste(screen, (margin + phone.bezel, margin + phone.bezel),
               rounded_mask(screen.size, phone.radius))
    if phone.angle:
        tile = tile.rotate(-phone.angle, resample=Image.Resampling.BICUBIC)
    origin = (phone.x - margin, phone.y - margin)
    # CSS box-shadow 0 50px 150px rgba(40, 36, 90, .30): blur radius 150 is
    # a Gaussian with a standard deviation of about 75.
    shadow = Image.new("RGBA", tile.size, (*SHADOW, 0))
    shadow.putalpha(tile.getchannel("A").filter(ImageFilter.GaussianBlur(75))
                    .point(lambda v: round(v * 0.30)))
    layer = Image.new("RGBA", canvas.size)
    layer.paste(shadow, (origin[0], origin[1] + 50))
    canvas = Image.alpha_composite(canvas, layer)
    layer = Image.new("RGBA", canvas.size)
    layer.paste(tile, origin)
    canvas = Image.alpha_composite(canvas, layer)
    left, top, right, bottom = tile.getchannel("A").point(lambda v: 255 if v > 8 else 0).getbbox()
    return canvas, Box(origin[0] + left, origin[1] + top, right - left, bottom - top)


def draw_lines(draw: ImageDraw.ImageDraw, x: int, top: int, lines: list[tuple[str, tuple[int, int, int]]],
               face: ImageFont.FreeTypeFont, line_height: int, align: str = "left") -> list[Box]:
    """Lay out lines as CSS does: each glyph run centered in its line box."""
    ascent, descent = face.getmetrics()
    anchor = "ls" if align == "left" else "ms"
    boxes = []
    for index, (text, fill) in enumerate(lines):
        baseline = top + index * line_height + (line_height - ascent - descent) / 2 + ascent
        draw.text((x, baseline), text, font=face, fill=(*fill, 255), anchor=anchor)
        left, upper, right, lower = draw.textbbox((x, baseline), text, font=face, anchor=anchor)
        boxes.append(Box(round(left), round(upper), round(right - left), round(lower - upper)))
    return boxes


def capture(name: str) -> Path:
    local = ROOT / "sources" / name
    return local if local.exists() else REPO / "docs/images" / name


def header() -> tuple[Image.Image, dict[str, Box]]:
    """The claim, with one purple word, over three iPhones fanned out below it."""
    canvas = background(HEADER.size)
    draw = ImageDraw.Draw(canvas)
    lines = draw_lines(draw, HEADER.size[0] // 2, 470,
                       [("Your Agents.", INK), ("Anywhere.", ACCENT)],
                       font(FONT, 220, "Bold"), 245, align="center")
    boxes = {f"headline-{index + 1}": box for index, box in enumerate(lines)}
    # Inside the width an iPhone shows (about x 330 to 3530), below the claim
    # and running past the bottom edge; narrower crops may cut them, never
    # the claim.
    for name, phone in (
        ("device-left", Phone(capture("changes-iphone.png"), 760, 1230, 660, 15, 90, -8)),
        ("device-right", Phone(capture("live-terminal-iphone.png"), 2420, 1230, 660, 15, 90, 8)),
        ("device-center", Phone(capture("console-iphone.png"), 1560, 1090, 720, 16, 98)),
    ):
        canvas, boxes[name] = place(canvas, phone)
    return canvas, boxes


def search_results() -> tuple[Image.Image, dict[str, Box]]:
    """A large claim, with one purple line, beside two overlapping iPhones."""
    canvas = background(SEARCH.size)
    draw = ImageDraw.Draw(canvas)
    # No kicker: the app name sits right above the card.
    headline = draw_lines(draw, 300, 760, [("Every Agent.", INK), ("One Console.", ACCENT)],
                          font(FONT, 280, "Bold"), 310)
    subhead = draw_lines(draw, 300, 1470, [("Follow, steer, and review", INK_SECONDARY),
                                           ("your coding agents on the go.", INK_SECONDARY)],
                         font(FONT, 116, "Regular"), 156)
    boxes = {f"headline-{index + 1}": box for index, box in enumerate(headline)}
    boxes |= {f"subhead-{index + 1}": box for index, box in enumerate(subhead)}
    for name, phone in (
        ("device-back", Phone(capture("changes-iphone.png"), 2180, 560, 900, 20, 122, -8)),
        ("device-front", Phone(capture("console-iphone.png"), 2720, 330, 940, 21, 127, 6)),
    ):
        canvas, boxes[name] = place(canvas, phone)
    return canvas, boxes


def check(asset: Asset, boxes: dict[str, Box]) -> list[str]:
    layout = asset.layout
    problems = []
    texts = {name: box for name, box in boxes.items() if name.startswith(("headline", "subhead"))}
    for name, box in texts.items():
        if not layout.contains(box):
            problems.append(f"{asset.slug}: {name} {box} leaves the layout area {layout}")
    # Devices may run past every edge but the top, and never cover the copy.
    for name, box in boxes.items():
        if name in texts:
            continue
        if not 0 <= box.y < asset.size[1]:
            problems.append(f"{asset.slug}: {name} {box} does not start on the canvas")
        for text_name, text in texts.items():
            if box.x < text.right and text.x < box.right and box.y < text.bottom and text.y < box.bottom:
                problems.append(f"{asset.slug}: {name} {box} covers {text_name}")
    return problems


def review(asset: Asset, image: Image.Image, target: Path) -> None:
    """A reduced copy with the safe (red) and layout (cyan) areas marked."""
    overlay = image.convert("RGB")
    draw = ImageDraw.Draw(overlay)
    for box, color in ((asset.layout, (64, 224, 255)), (asset.safe, (255, 64, 64))):
        draw.rectangle((box.x, box.y, box.right, box.bottom), outline=color, width=8)
    if asset is HEADER:
        # Community measurement of the iPhone product page crop, not Apple's.
        for x in (330, 3530):
            draw.line((x, 0, x, asset.size[1]), fill=(255, 210, 64), width=6)
    overlay.resize((asset.size[0] // 3, asset.size[1] // 3), Image.Resampling.LANCZOS).save(
        target, quality=90)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--review", type=Path, help="also write safe-area overlays here")
    args = parser.parse_args()
    (ROOT / "exports").mkdir(exist_ok=True)
    records, problems = [], []
    for asset, render in ((HEADER, header), (SEARCH, search_results)):
        image, boxes = render()
        problems += check(asset, boxes)
        target = ROOT / "exports" / f"{asset.slug}-{asset.size[0]}x{asset.size[1]}.png"
        image.convert("RGB").save(target, optimize=True)
        with Image.open(target) as exported:
            if exported.size != asset.size or exported.mode != "RGB":
                raise ValueError(f"Invalid creative asset export: {target}")
        if args.review:
            args.review.mkdir(parents=True, exist_ok=True)
            review(asset, image, args.review / f"{asset.slug}-review.jpg")
        records.append({
            "slug": asset.slug, "export": str(target.relative_to(ROOT)),
            "pixels": asset.size, "color_mode": "RGB", "has_alpha": False,
            "safe_area": [asset.safe.x, asset.safe.y, asset.safe.width, asset.safe.height],
            "layout_area": [asset.layout.x, asset.layout.y, asset.layout.width,
                            asset.layout.height],
            "boxes": {name: [b.x, b.y, b.width, b.height] for name, b in boxes.items()},
            "export_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        })
        print(target)
    (ROOT / "manifest.json").write_text(json.dumps(records, indent=2) + "\n")
    if problems:
        raise SystemExit("\n".join(problems))


if __name__ == "__main__":
    main()
