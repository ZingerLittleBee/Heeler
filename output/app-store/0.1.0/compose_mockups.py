#!/usr/bin/env python3
"""Compose deterministic App Store screenshots from exact Heeler captures."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[3]
OUTPUT_DIR = Path(__file__).resolve().parent / "iphone-6.9"
BACKGROUND_PATH = Path(__file__).resolve().parent / "assets" / "background.png"

CANVAS_SIZE = (1320, 2868)
SCREENSHOT_WIDTH = 1010
SCREENSHOT_TOP = 646
SCREENSHOT_RADIUS = 78

FONT_PATH = Path("/System/Library/Fonts/SFNS.ttf")
MONO_FONT_PATH = Path("/System/Library/Fonts/SFNSMono.ttf")


@dataclass(frozen=True)
class Mockup:
    output_name: str
    source_name: str
    headline: str
    subhead: str
    accent: tuple[int, int, int]


MOCKUPS = (
    Mockup(
        output_name="01-every-agent-one-console.png",
        source_name="console-iphone.png",
        headline="Every Agent.\nOne Console.",
        subhead="See who needs you first, across every Host.",
        accent=(152, 124, 255),
    ),
    Mockup(
        output_name="02-control-without-leaving-the-flow.png",
        source_name="agent-iphone.png",
        headline="Control Without\nLeaving the Flow",
        subhead="A live terminal and agent controls, built for iOS.",
        accent=(88, 214, 198),
    ),
    Mockup(
        output_name="03-compose-locally-send-once.png",
        source_name="composer-iphone.png",
        headline="Compose Locally.\nSend Once.",
        subhead="Draft with the full iOS keyboard, then deliver one complete prompt.",
        accent=(236, 113, 177),
    ),
    Mockup(
        output_name="04-your-agents-at-a-glance.png",
        source_name="live-activity-iphone.png",
        headline="Your Agents.\nAt a Glance.",
        subhead="See live Agent activity from the Lock Screen.",
        accent=(241, 204, 118),
    ),
)


def load_font(path: Path, size: int, variation: str | None = None) -> ImageFont.FreeTypeFont:
    font = ImageFont.truetype(str(path), size=size)
    if variation is not None:
        try:
            font.set_variation_by_name(variation)
        except (OSError, ValueError):
            pass
    return font


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1),
        radius=radius,
        fill=255,
    )
    return mask


def compose(mockup: Mockup) -> Path:
    background = Image.open(BACKGROUND_PATH).convert("RGB")
    canvas = ImageOps.fit(background, CANVAS_SIZE, method=Image.Resampling.LANCZOS)
    overlay = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    overlay_draw = ImageDraw.Draw(overlay)

    # Keep the generated texture visible at the edges while giving copy a quiet field.
    overlay_draw.rectangle((0, 0, CANVAS_SIZE[0], 630), fill=(4, 5, 12, 82))
    overlay_draw.line((96, 98, 170, 98), fill=(*mockup.accent, 255), width=8)

    kicker_font = load_font(MONO_FONT_PATH, 31, "Medium")
    headline_font = load_font(FONT_PATH, 91, "Bold")
    subhead_font = load_font(FONT_PATH, 37, "Regular")

    overlay_draw.text(
        (96, 126),
        "HEELER FOR HERDR",
        font=kicker_font,
        fill=(*mockup.accent, 255),
        spacing=4,
    )
    overlay_draw.multiline_text(
        (92, 188),
        mockup.headline,
        font=headline_font,
        fill=(250, 250, 253, 255),
        spacing=-2,
    )
    overlay_draw.multiline_text(
        (96, 455),
        mockup.subhead,
        font=subhead_font,
        fill=(211, 214, 225, 255),
        spacing=7,
    )
    canvas = Image.alpha_composite(canvas.convert("RGBA"), overlay)

    source_path = ROOT / "docs" / "images" / mockup.source_name
    screenshot = Image.open(source_path).convert("RGB")
    screenshot_height = round(screenshot.height * SCREENSHOT_WIDTH / screenshot.width)
    screenshot = screenshot.resize(
        (SCREENSHOT_WIDTH, screenshot_height),
        Image.Resampling.LANCZOS,
    )

    shot_x = (CANVAS_SIZE[0] - SCREENSHOT_WIDTH) // 2
    shot_y = SCREENSHOT_TOP
    mask = rounded_mask(screenshot.size, SCREENSHOT_RADIUS)

    shadow = Image.new("RGBA", CANVAS_SIZE, (0, 0, 0, 0))
    shadow_mask = Image.new("L", CANVAS_SIZE, 0)
    shadow_mask.paste(mask, (shot_x, shot_y + 14))
    shadow_mask = shadow_mask.filter(ImageFilter.GaussianBlur(34))
    shadow.putalpha(shadow_mask.point(lambda value: round(value * 0.72)))
    canvas = Image.alpha_composite(canvas, shadow)

    border_draw = ImageDraw.Draw(canvas)
    border_draw.rounded_rectangle(
        (
            shot_x - 4,
            shot_y - 4,
            shot_x + SCREENSHOT_WIDTH + 3,
            shot_y + screenshot_height + 3,
        ),
        radius=SCREENSHOT_RADIUS + 4,
        fill=(16, 17, 22, 255),
        outline=(*mockup.accent, 165),
        width=3,
    )
    canvas.paste(screenshot, (shot_x, shot_y), mask)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    output_path = OUTPUT_DIR / mockup.output_name
    canvas.convert("RGB").save(output_path, format="PNG", optimize=True)
    return output_path


def main() -> None:
    for mockup in MOCKUPS:
        print(compose(mockup))


if __name__ == "__main__":
    main()
