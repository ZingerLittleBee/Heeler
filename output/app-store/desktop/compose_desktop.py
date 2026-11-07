#!/usr/bin/env python3
"""Compose the Herdr desktop App Store screenshot for iPhone, iPad and iPhone Duo.

Two real captures from a Linux machine running the Herdr desktop app: the Hosts
list, where it sits beside Herdr TUI Hosts as a herdr-core Host, and the Agents
list filtered to it, where its spaces read as Workspaces. Pieces are scaled
uniformly and masked; no UI is repainted.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps


HERE = Path(__file__).resolve().parent
STORE = HERE.parent
SF = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
SLUG = "01a-herdr-desktop-too.png"

ACCENT = (96, 200, 240)
WHITE = (255, 255, 255)
HEADLINE = "Herdr Desktop, Too."
SUBHEAD = "Connect to Herdr TUI, the Herdr desktop app or herdr-core on macOS, Linux and Windows."
LABEL = "ITS SPACES AND AGENTS"
FOOTNOTE = "Live terminals, Chat and New Agent work there too."

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


def connector(canvas: Image.Image, center: int, top: int, size: int, gap: int) -> None:
    draw = ImageDraw.Draw(canvas)
    dot = max(4, size // 6)
    for index in range(3):
        y = top + index * gap * 2 // 3
        draw.ellipse((center - dot, y - dot, center + dot, y + dot), fill=(*WHITE, 110))
    draw.text((center, top + gap * 2), LABEL, font=font(MONO, size, "Medium"), fill=(*ACCENT, 255), anchor="mm")


def footnote(canvas: Image.Image, center: int, y: int, size: int) -> None:
    ImageDraw.Draw(canvas).text((center, y), FOOTNOTE, font=font(SF, size, "Regular"),
                                fill=(190, 196, 214, 255), anchor="mm")


def textured(path: Path, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(Image.open(path).convert("RGB"), size, method=Image.Resampling.LANCZOS).convert("RGBA")


def iphone() -> Image.Image:
    size = (1320, 2868)
    hosts = source("iphone-hosts.png", size)
    agents = source("iphone-agents.png", size)
    canvas = Image.alpha_composite(textured(STORE / "iphone-6.9/assets/background.png", size),
                                   Image.new("RGBA", size, (4, 5, 12, 120)))
    draw = ImageDraw.Draw(canvas)
    draw.line((96, 98, 170, 98), fill=(*ACCENT, 255), width=8)
    draw.text((96, 126), "HEELER FOR HERDR", font=font(MONO, 31, "Medium"), fill=(*ACCENT, 255))
    draw.text((92, 188), HEADLINE, font=font(SF, 91, "Bold"), fill=(250, 250, 253, 255))
    draw.multiline_text((96, 350), SUBHEAD.replace(" or herdr-core", "\nor herdr-core"), font=font(SF, 37, "Regular"),
                        fill=(214, 218, 232, 255), spacing=10)

    # The Hosts card: two Herdr TUI Hosts and the desktop's herdr-core Host.
    hosts_y = 620
    canvas = glow(canvas, (700, hosts_y + 300, 1360, hosts_y + 820), ACCENT, 110, 120)
    canvas = card(canvas, piece(hosts, (60, 625, 1260, 1294), 1.0), (60, hosts_y), 78)

    connector(canvas, size[0] // 2, hosts_y + 770, 30, 50)

    # The Agents list filtered to the desktop: its spaces, statuses and changes.
    agents_y = hosts_y + 1010
    canvas = glow(canvas, (-80, agents_y + 100, 700, agents_y + 760), ACCENT, 130, 70)
    canvas = card(canvas, piece(agents, (0, 318, 1320, 1204), 0.95), (33, agents_y), 78)
    footnote(canvas, size[0] // 2, 2690, 36)
    return canvas


def ipad() -> Image.Image:
    size = (2752, 2064)
    hosts = source("ipad-hosts.png", size)
    agents = source("ipad-agents.png", size)
    canvas = textured(STORE / "ipad-13/assets/background.png", size)
    veil = Image.new("RGBA", size)
    veil_draw = ImageDraw.Draw(veil)
    for y in range(size[1]):
        veil_draw.line((0, y, size[0], y), fill=(3, 5, 11, round(68 + 68 * y / size[1])))
    canvas = Image.alpha_composite(canvas, veil)
    draw = ImageDraw.Draw(canvas)
    draw.text((110, 75), "HEELER FOR IPAD", font=font(MONO, 30, "Medium"), fill=(*ACCENT, 255), anchor="lt")
    draw.text((106, 144), HEADLINE, font=font(SF, 112, "Bold"), fill=(250, 250, 253, 255), anchor="lt")
    draw.text((110, 290), SUBHEAD, font=font(SF, 41, "Regular"), fill=(211, 214, 225, 255), anchor="lt")

    middle = 1110
    # The Hosts sheet's card, left; the sidebar filtered to the desktop, right.
    hosts_piece = piece(hosts, (828, 685, 1924, 1131), 1.32)
    hosts_xy = (110, middle - hosts_piece.height // 2)
    canvas = glow(canvas, (hosts_xy[0] + 500, middle - 80, hosts_xy[0] + 1400, middle + 420), ACCENT, 140, 110)
    canvas = card(canvas, hosts_piece, hosts_xy, 66)

    agents_piece = piece(agents, (0, 62, 640, 640), 1.42)
    agents_xy = (size[0] - 110 - agents_piece.width, middle - agents_piece.height // 2 + 40)
    canvas = glow(canvas, (agents_xy[0] - 200, agents_xy[1] + 200, agents_xy[0] + 700, agents_xy[1] + 800),
                  ACCENT, 160, 60)
    canvas = card(canvas, agents_piece, agents_xy, 56)

    draw = ImageDraw.Draw(canvas)
    gap_left, gap_right = hosts_xy[0] + hosts_piece.width, agents_xy[0]
    for index in range(3):
        x = gap_left + (gap_right - gap_left) * (index + 1) // 4
        draw.ellipse((x - 6, middle - 6, x + 6, middle + 6), fill=(*WHITE, 110))
    draw.text((agents_xy[0] + 8, agents_xy[1] - 56), LABEL, font=font(MONO, 32, "Medium"),
              fill=(*ACCENT, 255), anchor="lm")
    footnote(canvas, size[0] // 2, 1930, 38)
    return canvas


def duo() -> Image.Image:
    size = (2853, 2007)
    hosts = source("duo-hosts.png", size)
    agents = source("duo-agents.png", size)
    # The other Duo screenshots sit on this near-black field.
    canvas = Image.new("RGBA", size, (3, 4, 10, 255))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((110, 63, 184, 69), fill=(*ACCENT, 255))
    draw.text((112, 115), "HEELER FOR HERDR", font=font(MONO, 29, "Medium"), fill=(*ACCENT, 255), anchor="ls")
    draw.text((112, 233), HEADLINE, font=font(SF, 103, "Bold"), fill=(250, 250, 253, 255), anchor="ls")
    draw.text((112, 322), SUBHEAD, font=font(SF, 41, "Regular"), fill=(211, 214, 225, 255), anchor="ls")

    # The full-width Hosts card, then the sidebar filtered to the desktop below it.
    hosts_piece = piece(hosts, (165, 367, 2496, 1036), 0.86)
    hosts_xy = ((size[0] - hosts_piece.width) // 2, 400)
    canvas = glow(canvas, (1500, hosts_xy[1] + 200, 2600, hosts_xy[1] + 760), ACCENT, 150, 110)
    canvas = card(canvas, hosts_piece, hosts_xy, 72)

    connector(canvas, size[0] // 2, hosts_xy[1] + hosts_piece.height + 45, 32, 54)

    agents_piece = piece(agents, (0, 40, 959, 770), 0.9)
    agents_xy = ((size[0] - agents_piece.width) // 2, hosts_xy[1] + hosts_piece.height + 210)
    canvas = glow(canvas, (agents_xy[0] - 400, agents_xy[1] + 100, agents_xy[0] + 500, agents_xy[1] + 700),
                  ACCENT, 160, 60)
    canvas = card(canvas, agents_piece, agents_xy, 64)
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
