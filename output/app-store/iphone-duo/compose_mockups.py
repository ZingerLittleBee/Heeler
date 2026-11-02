#!/usr/bin/env python3
"""Paint a landscape iPhone Duo capture into the framed App Store template.

The template keeps the background, title, bezel and hinge marks. Only pixels
inside the rounded screen shape are replaced.
"""
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).parent
SCREEN_LEFT, SCREEN_TOP, SCREEN_WIDTH, SCREEN_HEIGHT = 371, 440, 2110, 1484
CORNER_RADIUS = 122
SUPERSAMPLE = 4


def screen_mask() -> Image.Image:
    size = (SCREEN_WIDTH * SUPERSAMPLE, SCREEN_HEIGHT * SUPERSAMPLE)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1), CORNER_RADIUS * SUPERSAMPLE, fill=255
    )
    return mask.resize((SCREEN_WIDTH, SCREEN_HEIGHT), Image.LANCZOS)


def main() -> None:
    template = Image.open(ROOT / "source/frame-template.png").convert("RGB")
    capture = Image.open(ROOT / "source/01-console-and-chat-capture.png").convert("RGB")
    screen = capture.resize((SCREEN_WIDTH, SCREEN_HEIGHT), Image.LANCZOS)
    template.paste(screen, (SCREEN_LEFT, SCREEN_TOP), screen_mask())
    template.save(ROOT / "exports/01-console-and-chat.png", optimize=True)


if __name__ == "__main__":
    main()
