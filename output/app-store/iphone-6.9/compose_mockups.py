#!/usr/bin/env python3
"""Compose deterministic App Store screenshots from exact Heeler captures."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[3]
OUTPUT_DIR = Path(__file__).resolve().parent / "exports"
SOURCES_DIR = Path(__file__).resolve().parent / "sources"
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
        output_name="02-type-directly-stay-in-flow.png",
        source_name="live-terminal-iphone.png",
        headline="Type Directly.\nStay in Flow.",
        subhead="Route the iOS keyboard straight to the live Attach terminal.",
        accent=(236, 113, 177),
    ),
    Mockup(
        output_name="03-every-reply-as-a-chat.png",
        source_name="chat-iphone.png",
        headline="Every Reply.\nAs a Chat.",
        subhead="Read and answer Agents in native messages, not terminal text.",
        accent=(255, 159, 90),
    ),
    Mockup(
        output_name="04-control-without-leaving-the-flow.png",
        source_name="agent-iphone.png",
        headline="Control Without\nLeaving the Flow",
        subhead="A live terminal and agent controls, built for iOS.",
        accent=(88, 214, 198),
    ),
    Mockup(
        output_name="05-see-what-changed.png",
        source_name="changes-iphone.png",
        headline="See What\nChanged.",
        subhead="Every uncommitted file in the Agent's Checkout.",
        accent=(110, 207, 132),
    ),
    Mockup(
        output_name="06-your-shell-within-reach.png",
        source_name="terminal-iphone.png",
        headline="Your Shell.\nWithin Reach.",
        subhead="Every Host's shells, grouped by Workspace.",
        accent=(102, 166, 255),
    ),
    Mockup(
        output_name="07-skills-without-breaking-flow.png",
        source_name="skills-iphone.png",
        headline="Skills Without\nBreaking Flow",
        subhead="Find and insert Agent Skills without leaving the Composer.",
        accent=(184, 137, 255),
    ),
    Mockup(
        output_name="09-your-agents-at-a-glance.png",
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


DISPLAY_CORNER_ROWS = 240
DISPLAY_EDGE_BLEND = 3


def has_display_mask(screenshot: Image.Image) -> bool:
    """A `--mask=black` capture is black outside its rounded display."""
    return screenshot.getpixel((0, 0)) == (0, 0, 0)


def corner_black_runs(screenshot: Image.Image) -> list[int]:
    """For each row from the top and bottom edges, the shortest run of black
    from the side edges across the four corners."""
    pixels = screenshot.load()
    width, height = screenshot.size

    def black_run(row: int, x: int, step: int) -> int:
        count = 0
        while count < width // 2 and pixels[x + step * count, row] == (0, 0, 0):
            count += 1
        return count

    return [
        min(
            black_run(row, x, step)
            for row in (offset, height - 1 - offset)
            for x, step in ((0, 1), (width - 1, -1))
        )
        for offset in range(DISPLAY_CORNER_ROWS)
    ]


def display_mask(screenshots: list[Image.Image]) -> list[int]:
    """The display mask's width in each corner row. Every capture from one
    simulator shares it, but black content beside it reads as more mask, so the
    narrowest run across all captures is the mask itself."""
    runs = [corner_black_runs(shot) for shot in screenshots if has_display_mask(shot)]
    return [min(column) for column in zip(*runs)] if runs else []


def fill_display_corners(screenshot: Image.Image, mask: list[int]) -> Image.Image:
    """Paint the black outside a `--mask=black` capture's rounded display,
    since the frame's corners are tighter. Each row takes the color just inside
    the display's edge, past its anti-aliasing, so the fill matches whatever the
    corner shows."""
    if not has_display_mask(screenshot):
        return screenshot
    filled = screenshot.copy()
    pixels = filled.load()
    width, height = filled.size
    for offset, run in enumerate(mask):
        if run == 0:
            continue
        reach = run + DISPLAY_EDGE_BLEND
        for row in (offset, height - 1 - offset):
            left = pixels[reach, row]
            right = pixels[width - 1 - reach, row]
            for x in range(reach):
                pixels[x, row] = left
                pixels[width - 1 - x, row] = right
    return filled


def source_path(mockup: Mockup) -> Path:
    """A store-only capture here wins over the README image of the same name."""
    path = SOURCES_DIR / mockup.source_name
    return path if path.exists() else ROOT / "docs" / "images" / mockup.source_name


def compose(mockup: Mockup, screenshot: Image.Image) -> Path:
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
    screenshots = [Image.open(source_path(mockup)).convert("RGB") for mockup in MOCKUPS]
    mask = display_mask(screenshots)
    for mockup, screenshot in zip(MOCKUPS, screenshots):
        print(compose(mockup, fill_display_corners(screenshot, mask)))


if __name__ == "__main__":
    main()
