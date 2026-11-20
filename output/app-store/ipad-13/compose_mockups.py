#!/usr/bin/env python3
"""Render the approved iPad layout with exact, proportionally scaled captures."""

from __future__ import annotations

import hashlib
import html
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from backdrop import backdrop  # noqa: E402


ROOT = Path(__file__).resolve().parent
SIZE = (2752, 2064)
SHOT_SIZE = (2112, 1584)
SHOT_ORIGIN = (320, 428)
# The accent's light sits behind the top of the screenshot, flat enough to leave the headline on graphite.
LIGHT_CENTER = (SIZE[0] / 2, SHOT_ORIGIN[1] + 40)
LIGHT_RADII = (1500, 320)
FONT = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"


@dataclass(frozen=True)
class Mockup:
    slug: str
    source: str
    headline: str
    subhead: str
    accent: tuple[int, int, int]


MOCKUPS = (
    Mockup(
        "01-fits-your-workspace", "05-windowed-console.png",
        "Fits Your Workspace.",
        "Keep your agent console close in a flexible iPad window.",
        (102, 166, 255),
    ),
    Mockup(
        "02-every-agent-one-console", "01-console.png",
        "Every Agent. One Console.",
        "Follow your agents and their work, side by side.",
        (152, 124, 255),
    ),
    Mockup(
        "03-type-directly-stay-in-flow", "02-terminal-keyboard.png",
        "Type Directly. Stay in Flow.",
        "Type straight into your agent's terminal.",
        (236, 113, 177),
    ),
    Mockup(
        "04-see-what-changed", "06-changes.png",
        "See What Changed.",
        "Every uncommitted file in the Agent's Checkout, beside your agents.",
        (110, 207, 132),
    ),
    Mockup(
        "05-every-change-line-by-line", "07-diff.png",
        "Every Change. Line by Line.",
        "Read any file side by side or unified, with word changes marked.",
        (255, 159, 90),
    ),    Mockup(
        "06-skills-within-reach", "03-skills.png",
        "Your Skills. Within Reach.",
        "Find and add skills without leaving your conversation.",
        (184, 137, 255),
    ),
    Mockup(
        "07-a-shell-when-you-need-one", "04-terminal.png",
        "A Shell When You Need One.",
        "Open a plain terminal in any workspace, with Text and Keys modes.",
        (88, 214, 198),
    ),
)


def font(path: str, size: int, style: str) -> ImageFont.FreeTypeFont:
    result = ImageFont.truetype(path, size)
    result.set_variation_by_name(style)
    return result


def compose(item: Mockup) -> dict:
    source_path = ROOT / "sources" / item.source
    source = Image.open(source_path).convert("RGB")
    if source.size != SIZE:
        raise ValueError(f"Unexpected capture size: {source_path}: {source.size}")
    if source.width * SHOT_SIZE[1] != source.height * SHOT_SIZE[0]:
        raise ValueError("The screenshot must retain its original aspect ratio")

    canvas = backdrop(SIZE, light=(item.accent, LIGHT_CENTER, LIGHT_RADII))
    draw = ImageDraw.Draw(canvas)
    draw.text((110, 75), "HEELER FOR IPAD", font=font(MONO, 30, "Medium"),
              fill=(*item.accent, 255), anchor="lt")
    headline_font = font(FONT, 112, "Bold")
    if draw.textlength(item.headline, font=headline_font) > SIZE[0] - 220:
        raise ValueError(f"Headline exceeds the safe area: {item.headline}")
    draw.text((106, 144), item.headline, font=headline_font,
              fill=(250, 250, 253, 255), anchor="lt")
    subhead_font = font(FONT, 41, "Regular")
    if draw.textlength(item.subhead, font=subhead_font) > SIZE[0] - 220:
        raise ValueError(f"Subhead exceeds the safe area: {item.subhead}")
    draw.text((110, 290), item.subhead, font=subhead_font,
              fill=(211, 214, 225, 255), anchor="lt")

    x, y = SHOT_ORIGIN
    width, height = SHOT_SIZE
    mask = Image.new("L", SHOT_SIZE)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, width - 1, height - 1), radius=40, fill=255)
    shadow_mask = Image.new("L", SIZE)
    shadow_mask.paste(mask, (x, y + 20))
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(48))
    shadow = Image.new("RGBA", SIZE, (0, 0, 0, 0))
    shadow.putalpha(shadow_mask.point(lambda value: round(value * 0.65)))
    canvas = Image.alpha_composite(canvas, shadow)
    ImageDraw.Draw(canvas).rounded_rectangle(
        (x - 4, y - 4, x + width + 3, y + height + 3), radius=44,
        fill=(16, 17, 22, 255), outline=(*item.accent, 255), width=3,
    )
    # The capture is scaled uniformly; no UI is repainted or rearranged.
    canvas.paste(source.resize(SHOT_SIZE, Image.Resampling.LANCZOS), (x, y), mask)
    target = ROOT / "exports" / f"{item.slug}.png"
    canvas.convert("RGB").save(target, optimize=True)
    with Image.open(target) as exported:
        if exported.size != SIZE or exported.mode != "RGB":
            raise ValueError(f"Invalid App Store export: {target}")
    return {
        **asdict(item), "export": str(target.relative_to(ROOT)),
        "source_sha256": hashlib.sha256(source_path.read_bytes()).hexdigest(),
        "export_sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        "pixels": SIZE, "color_mode": "RGB", "has_alpha": False,
        "screenshot_origin": SHOT_ORIGIN, "screenshot_pixels": SHOT_SIZE,
    }


def main() -> None:
    (ROOT / "exports").mkdir(exist_ok=True)
    records = [compose(item) for item in MOCKUPS]
    (ROOT / "manifest.json").write_text(json.dumps(records, indent=2) + "\n")
    cards = "\n".join(
        f'<figure><a href="{record["export"]}"><img src="{record["export"]}" '
        f'alt="{html.escape(record["headline"])}"></a><figcaption>'
        f'{html.escape(record["headline"])} · <a href="{record["export"]}" download>'
        'Download PNG</a></figcaption></figure>' for record in records
    )
    (ROOT / "index.html").write_text(
        '<!doctype html><html lang="en"><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>Heeler iPad App Store screenshots</title><style>'
        'body{margin:32px auto;padding:0 24px;max-width:1400px;background:#111114;'
        'color:#eee;font:16px/1.5 -apple-system,BlinkMacSystemFont,sans-serif}'
        'h1{font-size:28px}p,figcaption{color:#b8b8c0}a{color:#c4b2ff}'
        'figure{margin:40px 0}img{display:block;width:100%;height:auto;border-radius:10px}'
        'figcaption{margin-top:10px}</style><h1>Heeler for iPad</h1>'
        '<p>Seven landscape App Store mockups · 2752 × 2064 · opaque RGB PNG.<br>'
        'Real simulator captures with English marketing copy. The captured '
        'session titles remain in Chinese.</p>' + cards + '</html>'
    )
    # A review contact sheet is separate from the upload-ready exports.
    rows = (len(records) + 1) // 2
    sheet = Image.new("RGB", (1376, 14 + rows * 546), (20, 20, 24))
    for index, record in enumerate(records):
        preview = Image.open(ROOT / record["export"]).resize((660, 495), Image.Resampling.LANCZOS)
        px, py = 14 + (index % 2) * 688, 14 + (index // 2) * 546
        sheet.paste(preview, (px, py))
        ImageDraw.Draw(sheet).text((px, py + 506), f'{index + 1:02d}  {record["headline"]}',
                                  font=font(FONT, 20, "Medium"), fill=(225, 225, 231))
    sheet.save(ROOT / "contact-sheet.jpg", quality=94)
    for record in records:
        print(ROOT / record["export"])


if __name__ == "__main__":
    main()
