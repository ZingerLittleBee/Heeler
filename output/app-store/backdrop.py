"""The field behind the App Store screenshots: the landing page's graphite.

Neutral near-black, a little lighter toward the top edge, with an optional
faint light in one image's accent. Drawn in floating point and dithered, so
the slow gradients do not band, and the same call always gives the same pixels.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

TOP = (16.0, 17.0, 20.0)
BOTTOM = (9.0, 10.0, 12.0)
TOP_LIGHT = (11.0, 11.5, 13.0)
ACCENT_STRENGTH = 0.15

Color = tuple[int, int, int]
Point = tuple[float, float]


def _falloff(size: tuple[int, int], center: Point, radii: Point) -> np.ndarray:
    """A Gaussian spot, 1 at `center` and about 0.14 one radius away."""
    x = np.exp(-2 * ((np.arange(size[0]) - center[0]) / radii[0]) ** 2)
    y = np.exp(-2 * ((np.arange(size[1]) - center[1]) / radii[1]) ** 2)
    return np.outer(y, x)[..., None]


def backdrop(size: tuple[int, int], light: tuple[Color, Point, Point] | None = None) -> Image.Image:
    """The field at `size`, as RGBA. `light` is an accent color, its center and its radii."""
    width, height = size
    ramp = np.linspace(0, 1, height)[:, None, None]
    ramp = ramp * ramp * (3 - 2 * ramp)
    field = np.array(TOP) * (1 - ramp) + np.array(BOTTOM) * ramp
    field = field + _falloff(size, (width / 2, -0.06 * height), (0.95 * width, 0.30 * height)) * np.array(TOP_LIGHT)
    if light is not None:
        color, center, radii = light
        field = field + _falloff(size, center, radii) * np.array(color, float) * ACCENT_STRENGTH
    # Interleaved gradient noise: half a level of dither with no random state.
    x, y = np.arange(width)[None, :], np.arange(height)[:, None]
    noise = (52.9829189 * ((0.06711056 * x + 0.00583715 * y) % 1)) % 1 - 0.5
    pixels = np.clip(np.rint(field + noise[..., None]), 0, 255).astype(np.uint8)
    return Image.fromarray(pixels, "RGB").convert("RGBA")
