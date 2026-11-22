#!/usr/bin/env python3
"""Paint landscape iPhone Duo captures into their framed App Store templates.

A template keeps the background, title, bezel and hinge marks. Only pixels
inside the rounded screen shape are replaced.
"""
from pathlib import Path

from PIL import Image, ImageDraw

from reletter_eyebrow import reletter

ROOT = Path(__file__).parent
SCREEN_LEFT, SCREEN_TOP, SCREEN_WIDTH, SCREEN_HEIGHT = 371, 440, 2110, 1484
CORNER_RADIUS = 122
SUPERSAMPLE = 4

# Export name, its template, and whether the template's eyebrow still names herdr.
MOCKUPS = (
    ("01-console-and-chat", "frame-template.png", True),
    ("03-chat", "03-chat-template.png", False),
)


def screen_mask() -> Image.Image:
    size = (SCREEN_WIDTH * SUPERSAMPLE, SCREEN_HEIGHT * SUPERSAMPLE)
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size[0] - 1, size[1] - 1), CORNER_RADIUS * SUPERSAMPLE, fill=255
    )
    return mask.resize((SCREEN_WIDTH, SCREEN_HEIGHT), Image.LANCZOS)


def main() -> None:
    mask = screen_mask()
    for name, template_name, names_herdr in MOCKUPS:
        template = Image.open(ROOT / "source" / template_name).convert("RGB")
        if names_herdr:
            template = reletter(template)
        capture = Image.open(ROOT / f"source/{name}-capture.png").convert("RGB")
        screen = capture.resize((SCREEN_WIDTH, SCREEN_HEIGHT), Image.LANCZOS)
        template.paste(screen, (SCREEN_LEFT, SCREEN_TOP), mask)
        template.save(ROOT / f"exports/{name}.png", optimize=True)


if __name__ == "__main__":
    main()
