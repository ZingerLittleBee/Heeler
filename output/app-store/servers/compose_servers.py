#!/usr/bin/env python3
"""Compose the Servers App Store screenshot for iPhone, iPad and iPhone Duo.

Two real captures of one machine that runs Herdr TUI, herdr-core, tmux and Rex:
the Hosts list, where its row carries a tag per Server, and its Host page,
where each Server has a switch. Pieces are scaled uniformly and masked; no UI
is repainted.
"""

from __future__ import annotations

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


HERE = Path(__file__).resolve().parent
STORE = HERE.parent
sys.path.insert(0, str(STORE))
from backdrop import backdrop  # noqa: E402

SF = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
SLUG = "01a-herdr-tmux-rex.png"

ACCENT = (96, 200, 240)
WHITE = (255, 255, 255)
HEADLINE = "Herdr, tmux or Rex."
SUBHEAD = "Add a machine once. Heeler finds every server it runs: Herdr TUI, the Herdr desktop app, tmux and Rex."
LABEL = "ONE HOST, FOUR SERVERS"
FOOTNOTE = "Live terminals and Chat on all four."

IPHONE = (1320, 2868)
# The Hosts list's row, and the Host page from its Servers heading to the footer.
IPHONE_ROW = (60, 636, 1260, 857)
IPHONE_SERVERS = (30, 340, 1290, 1664)

Box = tuple[int, int, int, int]


def font(path: str, size: int, style: str) -> ImageFont.FreeTypeFont:
    result = ImageFont.truetype(path, size)
    result.set_variation_by_name(style)
    return result


def source(name: str, size: tuple[int, int]) -> Image.Image:
    image = Image.open(HERE / "sources" / name).convert("RGB")
    if image.size != size:
        raise ValueError(f"Unexpected capture size: {name}: {image.size}")
    return image


def piece(image: Image.Image, box: Box, scale: float) -> Image.Image:
    cut = image.crop(box)
    return cut.resize((round(cut.width * scale), round(cut.height * scale)), Image.Resampling.LANCZOS)


def rounded(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", (size[0] * 4, size[1] * 4), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, mask.width - 1, mask.height - 1), radius * 4, fill=255)
    return mask.resize(size, Image.Resampling.LANCZOS)


def glow(canvas: Image.Image, box: Box, color: tuple[int, int, int], blur: int, alpha: int) -> Image.Image:
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(box, fill=(*color, alpha))
    return Image.alpha_composite(canvas, layer.filter(ImageFilter.GaussianBlur(blur)))


def card(canvas: Image.Image, image: Image.Image, xy: tuple[int, int], radius: int) -> Image.Image:
    """Paste a rounded piece with a soft shadow and a faint edge."""
    mask = rounded(image.size, radius)
    shadow = Image.new("L", canvas.size, 0)
    shadow.paste(mask.point(lambda value: value * 170 // 255), (xy[0], xy[1] + 18))
    dark = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    dark.putalpha(shadow.filter(ImageFilter.GaussianBlur(radius * 0.7)))
    canvas = Image.alpha_composite(canvas, dark)
    canvas.paste(image, xy, mask)
    edge = Image.new("L", image.size, 0)
    ImageDraw.Draw(edge).rounded_rectangle((0, 0, image.width - 1, image.height - 1), radius, outline=38, width=3)
    outline = Image.new("RGBA", canvas.size, (*WHITE, 0))
    alpha = Image.new("L", canvas.size, 0)
    alpha.paste(edge, xy)
    outline.putalpha(alpha)
    return Image.alpha_composite(canvas, outline)


def dots(canvas: Image.Image, start: tuple[int, int], step: tuple[int, int], radius: int) -> None:
    draw = ImageDraw.Draw(canvas)
    for index in range(3):
        x, y = start[0] + step[0] * index, start[1] + step[1] * index
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=(*WHITE, 110))


def label(canvas: Image.Image, xy: tuple[int, int], size: int, anchor: str) -> None:
    ImageDraw.Draw(canvas).text(xy, LABEL, font=font(MONO, size, "Medium"), fill=(*ACCENT, 255), anchor=anchor)


def footnote(canvas: Image.Image, center: int, y: int, size: int) -> None:
    ImageDraw.Draw(canvas).text((center, y), FOOTNOTE, font=font(SF, size, "Regular"),
                                fill=(190, 196, 214, 255), anchor="mm")


def side_by_side(canvas: Image.Image, row: Image.Image, servers: Image.Image, margin: int, middle: int,
                 radii: tuple[int, int]) -> Image.Image:
    """The Host's row on the left, its Servers on the right, joined by dots."""
    row_xy = (margin, middle - row.height // 2)
    servers_xy = (canvas.width - margin - servers.width, middle - servers.height // 2)
    canvas = glow(canvas, (row_xy[0] + 300, middle - 260, row_xy[0] + row.width + 100, middle + 320), ACCENT, 150, 110)
    canvas = card(canvas, row, row_xy, radii[0])
    canvas = glow(canvas, (servers_xy[0] - 200, servers_xy[1] + 300, servers_xy[0] + 600, servers_xy[1] + 900),
                  ACCENT, 160, 60)
    canvas = card(canvas, servers, servers_xy, radii[1])
    gap_left, gap_right = row_xy[0] + row.width, servers_xy[0]
    step = (gap_right - gap_left) // 4
    dots(canvas, (gap_left + step, middle), (step, 0), 6)
    label(canvas, (row_xy[0] + 8, row_xy[1] - 56), 32, "lm")
    return canvas


def iphone() -> Image.Image:
    hosts = source("iphone-hosts.png", IPHONE)
    host = source("iphone-host.png", IPHONE)
    canvas = backdrop(IPHONE)
    draw = ImageDraw.Draw(canvas)
    draw.line((96, 98, 170, 98), fill=(*ACCENT, 255), width=8)
    draw.text((96, 126), "HEELER FOR IPHONE", font=font(MONO, 31, "Medium"), fill=(*ACCENT, 255))
    draw.text((92, 188), HEADLINE, font=font(SF, 91, "Bold"), fill=(250, 250, 253, 255))
    draw.multiline_text((96, 350), SUBHEAD.replace(": ", ":\n"), font=font(SF, 37, "Regular"),
                        fill=(214, 218, 232, 255), spacing=10)

    row_y = 640
    row = piece(hosts, IPHONE_ROW, 1.0)
    canvas = glow(canvas, (640, row_y - 120, 1360, row_y + 380), ACCENT, 110, 120)
    canvas = card(canvas, row, (60, row_y), 78)

    center = IPHONE[0] // 2
    dots(canvas, (center, row_y + row.height + 95), (0, 33), 5)
    label(canvas, (center, row_y + row.height + 195), 30, "mm")

    servers_y = row_y + row.height + 320
    canvas = glow(canvas, (-80, servers_y + 200, 700, servers_y + 900), ACCENT, 130, 70)
    canvas = card(canvas, piece(host, IPHONE_SERVERS, 1.0), (30, servers_y), 78)
    footnote(canvas, center, 2690, 36)
    return canvas


def ipad() -> Image.Image:
    size = (2752, 2064)
    hosts = source("ipad-hosts.png", size)
    host = source("ipad-host.png", size)
    canvas = backdrop(size)
    draw = ImageDraw.Draw(canvas)
    draw.text((110, 75), "HEELER FOR IPAD", font=font(MONO, 30, "Medium"), fill=(*ACCENT, 255), anchor="lt")
    draw.text((106, 144), HEADLINE, font=font(SF, 112, "Bold"), fill=(250, 250, 253, 255), anchor="lt")
    draw.text((110, 290), SUBHEAD, font=font(SF, 41, "Regular"), fill=(211, 214, 225, 255), anchor="lt")

    # Both pieces are the top of a sheet: the Hosts list, and the Host page down to the Servers footer.
    canvas = side_by_side(canvas, piece(hosts, (796, 372, 1956, 884), 1.0), piece(host, (796, 372, 1956, 1390), 1.0),
                          110, 1130, (76, 76))
    footnote(canvas, size[0] // 2, 1930, 38)
    return canvas


def duo() -> Image.Image:
    size = (2853, 2007)
    # Folded, the Duo lays these pages out as an iPhone does, so the pieces are the iPhone's.
    hosts = source("iphone-hosts.png", IPHONE)
    host = source("iphone-host.png", IPHONE)
    # The other Duo screenshots sit on this near-black field.
    canvas = Image.new("RGBA", size, (3, 4, 10, 255))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((110, 63, 184, 69), fill=(*ACCENT, 255))
    draw.text((112, 115), "HEELER FOR IPHONE", font=font(MONO, 29, "Medium"), fill=(*ACCENT, 255), anchor="ls")
    draw.text((112, 233), HEADLINE, font=font(SF, 103, "Bold"), fill=(250, 250, 253, 255), anchor="ls")
    draw.text((112, 322), SUBHEAD, font=font(SF, 41, "Regular"), fill=(211, 214, 225, 255), anchor="ls")

    canvas = side_by_side(canvas, piece(hosts, IPHONE_ROW, 1.0), piece(host, IPHONE_SERVERS, 0.95),
                          112, 1070, (78, 74))
    footnote(canvas, size[0] // 2, 1945, 38)
    return canvas


def main() -> None:
    for slot, render in (("iphone-6.9", iphone), ("ipad-13", ipad), ("iphone-duo", duo)):
        target = STORE / slot / "exports" / SLUG
        image = render().convert("RGB")
        image.save(target, optimize=True)
        print(target, image.size)


if __name__ == "__main__":
    main()
