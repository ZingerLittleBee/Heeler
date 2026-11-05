#!/usr/bin/env python3
"""Compose the Voice Input App Store screenshot for iPhone, iPad and iPhone Duo.

Each image cuts the Composer out of two real captures, one while recording and
one after the transcript lands, and enlarges the recording bar. Pieces are
scaled uniformly and masked; no UI is repainted.
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont, ImageOps


HERE = Path(__file__).resolve().parent
STORE = HERE.parent
SF = "/System/Library/Fonts/SFNS.ttf"
MONO = "/System/Library/Fonts/SFNSMono.ttf"
SLUG = "01b-just-say-it.png"

ACCENT = (255, 112, 102)
WHITE = (255, 255, 255)
HEADLINE = "Just Say It."
SUBHEAD = "Speak your prompt. It lands in the Composer, ready to review and send."
LABEL = "TRANSCRIBED AT THE CARET"
FOOTNOTE = "Bring your own speech service key."

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


def edges(size: tuple[int, int], left: int = 0, right: int = 0, top: int = 0, bottom: int = 0) -> Image.Image:
    """Opaque mask whose sides ease out to transparent over the given widths."""
    ramp = Image.linear_gradient("L").point(lambda value: value * value // 255)  # transparent at the top
    bands = (
        (top, lambda width: ramp.resize((size[0], width)), (0, 0)),
        (bottom, lambda width: ramp.rotate(180).resize((size[0], width)), (0, size[1] - bottom)),
        (left, lambda width: ramp.transpose(Image.Transpose.TRANSPOSE).resize((width, size[1])), (0, 0)),
        (right, lambda width: ramp.transpose(Image.Transpose.TRANSVERSE).resize((width, size[1])), (size[0] - right, 0)),
    )
    mask = Image.new("L", size, 255)
    for width, band, xy in bands:
        if width:
            layer = Image.new("L", size, 255)
            layer.paste(band(width), xy)
            mask = ImageChops.multiply(mask, layer)
    return mask


def glow(canvas: Image.Image, box: Box, color: tuple[int, int, int], blur: int, alpha: int) -> Image.Image:
    layer = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(box, fill=(*color, alpha))
    return Image.alpha_composite(canvas, layer.filter(ImageFilter.GaussianBlur(blur)))


def card(canvas: Image.Image, image: Image.Image, xy: tuple[int, int], radius: int, fade_left: int = 0) -> Image.Image:
    """Paste a rounded piece with a soft shadow and a faint edge."""
    fade = edges(image.size, left=fade_left)
    mask = ImageChops.multiply(rounded(image.size, radius), fade)
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
    alpha.paste(ImageChops.multiply(edge, fade), xy)
    outline.putalpha(alpha)
    return Image.alpha_composite(canvas, outline)


def context(canvas: Image.Image, image: Image.Image, xy: tuple[int, int], sides: int = 0) -> None:
    """The Agent's last reply, fading in from the top, for a sense of place."""
    layer = image.convert("RGBA")
    layer.putalpha(edges(image.size, left=sides, right=sides, top=image.height * 4 // 5, bottom=14))
    canvas.alpha_composite(layer, xy)


def connector(canvas: Image.Image, center: int, top: int, size: int, gap: int) -> None:
    draw = ImageDraw.Draw(canvas)
    draw.text((center, top), LABEL, font=font(MONO, size, "Medium"), fill=(*ACCENT, 255), anchor="mm")
    dot = max(4, size // 6)
    for index in range(3):
        y = top + gap + index * gap * 2 // 3
        draw.ellipse((center - dot, y - dot, center + dot, y + dot), fill=(*WHITE, 110))


def footnote(canvas: Image.Image, center: int, y: int, size: int) -> None:
    ImageDraw.Draw(canvas).text((center, y), FOOTNOTE, font=font(SF, size, "Regular"),
                                fill=(190, 196, 214, 255), anchor="mm")


def textured(path: Path, size: tuple[int, int]) -> Image.Image:
    return ImageOps.fit(Image.open(path).convert("RGB"), size, method=Image.Resampling.LANCZOS).convert("RGBA")


def iphone() -> Image.Image:
    size = (1320, 2868)
    recording = source("iphone-recording.png", size)
    draft = source("iphone-draft.png", size)
    canvas = Image.alpha_composite(textured(STORE / "iphone-6.9/assets/background.png", size),
                                   Image.new("RGBA", size, (4, 5, 12, 120)))
    draw = ImageDraw.Draw(canvas)
    draw.line((96, 98, 170, 98), fill=(*ACCENT, 255), width=8)
    draw.text((96, 126), "HEELER FOR HERDR", font=font(MONO, 31, "Medium"), fill=(*ACCENT, 255))
    draw.text((92, 188), HEADLINE, font=font(SF, 91, "Bold"), fill=(250, 250, 253, 255))
    draw.multiline_text((96, 350), SUBHEAD.replace(" ready", "\nready"), font=font(SF, 37, "Regular"),
                        fill=(214, 218, 232, 255), spacing=10)

    bar_y = 1480
    context(canvas, recording.crop((0, 1660, 1320, 2446)), (0, bar_y - 820))
    canvas = glow(canvas, (880, bar_y - 150, 1330, bar_y + 360), ACCENT, 100, 160)
    canvas = glow(canvas, (60, bar_y - 60, 960, bar_y + 260), WHITE, 120, 36)
    # The bar is wider than the canvas on purpose: both ends bleed off.
    canvas = card(canvas, piece(recording, (36, 2452, 1284, 2622), 1.22), (-34, bar_y), 88)
    connector(canvas, size[0] // 2, bar_y + 300, 30, 50)
    canvas = card(canvas, piece(draft, (36, 1219, 1284, 1684), 1.0), (36, bar_y + 500), 72)
    footnote(canvas, size[0] // 2, 2690, 36)
    return canvas


def ipad() -> Image.Image:
    size = (2752, 2064)
    recording = source("ipad-recording.png", size)
    draft = source("ipad-draft.png", size)
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

    bar_y = 850
    context(canvas, recording.crop((660, 1512, 2732, 1812)), (340, bar_y - 334), sides=90)
    canvas = glow(canvas, (2060, bar_y - 220, 2760, bar_y + 420), ACCENT, 130, 170)
    canvas = glow(canvas, (500, bar_y - 80, 2000, bar_y + 300), WHITE, 150, 30)
    # The wide iPad bar keeps its waveform at the right; its idle start fades out.
    canvas = card(canvas, piece(recording, (1240, 1816, 2632, 1929), 1.9), (167, bar_y), 104, fade_left=620)
    connector(canvas, size[0] // 2, bar_y + 360, 32, 54)
    canvas = card(canvas, piece(draft, (760, 752, 2632, 973), 1.25), (206, bar_y + 580), 72)
    footnote(canvas, size[0] // 2, 1930, 38)
    return canvas


def duo() -> Image.Image:
    size = (2853, 2007)
    recording = source("duo-recording.png", size)
    draft = source("duo-draft.png", size)
    # The other Duo screenshots sit on this near-black field.
    canvas = Image.new("RGBA", size, (3, 4, 10, 255))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((110, 63, 184, 69), fill=(*ACCENT, 255))
    draw.text((112, 115), "HEELER FOR HERDR", font=font(MONO, 29, "Medium"), fill=(*ACCENT, 255), anchor="ls")
    draw.text((112, 233), HEADLINE, font=font(SF, 103, "Bold"), fill=(250, 250, 253, 255), anchor="ls")
    draw.text((112, 322), SUBHEAD, font=font(SF, 41, "Regular"), fill=(211, 214, 225, 255), anchor="ls")

    bar_y = 800
    context(canvas, recording.crop((962, 1180, 2598, 1588)), (608, bar_y - 442), sides=36)
    canvas = glow(canvas, (1980, bar_y - 220, 2700, bar_y + 520), ACCENT, 140, 170)
    canvas = glow(canvas, (300, bar_y - 80, 1900, bar_y + 360), WHITE, 160, 30)
    canvas = card(canvas, piece(recording, (997, 1593, 2564, 1762), 1.7), (94, bar_y), 120)
    connector(canvas, size[0] // 2, bar_y + 395, 32, 54)
    canvas = card(canvas, piece(draft, (997, 663, 2564, 1060), 1.0), (643, bar_y + 590), 84)
    footnote(canvas, size[0] // 2, 1925, 38)
    return canvas


def main() -> None:
    for slot, render in (("iphone-6.9", iphone), ("ipad-13", ipad), ("iphone-duo", duo)):
        target = STORE / slot / "exports" / SLUG
        image = render().convert("RGB")
        image.save(target, optimize=True)
        print(target, image.size)


if __name__ == "__main__":
    main()
