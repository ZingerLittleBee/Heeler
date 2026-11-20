#!/usr/bin/env python3
"""Replace the eyebrow line baked into an iPhone Duo App Store screenshot.

Seven images of this slot exist only in App Store Connect, and the frame
template of the first carries its eyebrow too. This covers the old line with
the empty background beside it and writes the new one in the image's own
accent, which it reads from the bar above. No application pixels are touched.

    python3 reletter_eyebrow.py downloaded.png [more.png ...] --out DIR
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

MONO = "/System/Library/Fonts/SFNSMono.ttf"
EYEBROW = "HEELER FOR IPHONE"
SIZE = (2853, 2007)
# The old line sits in this band; the patch comes from the same rows further right.
BAND = (100, 84, 520, 126)
DONOR_X = 560
BASELINE = (110, 116)
BAR = (147, 66)


def reletter(image: Image.Image) -> Image.Image:
    if image.size != SIZE:
        raise ValueError(f"Not an iPhone Duo screenshot: {image.size}")
    image = image.convert("RGB")
    accent = image.getpixel(BAR)
    if max(accent) < 120:
        raise ValueError(f"No accent bar at {BAR}: {accent}")
    width = BAND[2] - BAND[0]
    donor = image.crop((DONOR_X, BAND[1], DONOR_X + width, BAND[3]))
    if max(max(pixel) for pixel in donor.get_flattened_data()) > 60:
        raise ValueError("The background beside the eyebrow is not empty")
    image.paste(donor, BAND[:2])
    font = ImageFont.truetype(MONO, 29)
    font.set_variation_by_name("Medium")
    ImageDraw.Draw(image).text(BASELINE, EYEBROW, font=font, fill=accent, anchor="ls")
    return image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("images", nargs="+", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="directory for the re-lettered copies")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    for path in args.images:
        target = args.out / path.name
        reletter(Image.open(path)).save(target, optimize=True)
        print(target)


if __name__ == "__main__":
    main()
