#!/usr/bin/env python3
"""Makes Halden's app icon as an Icon Composer icon (`App/AppIcon.icon`): layers the system turns
into Liquid Glass, with light, depth, and the dark, tinted and clear looks by itself.

    python3 ios/Icon/make_icon.py          # writes App/AppIcon.icon and Icon/preview.svg

The idea: the six blades of a camera's aperture in the colours of a photo library, each a layer
of its own, so where they lie over each other the glass mixes their colours; in the middle the
opening they leave.
"""

import json
import math
import pathlib
import shutil

SIZE = 1024
CENTER = SIZE / 2
HERE = pathlib.Path(__file__).resolve().parent
ICON = HERE.parent / "App" / "AppIcon.icon"

# Warm to cool and round again: a light and a deep tone for each blade's gradient.
BLADES = [
    ("sun", "#FFE066", "#FFA41B"),
    ("coral", "#FF9E80", "#FF4A3D"),
    ("rose", "#FF9CC2", "#E8337A"),
    ("violet", "#C9A6FF", "#8A4DF0"),
    ("sky", "#94D7FF", "#1484FF"),
    ("leaf", "#A3F2AE", "#25BE4B"),
]

OUTER = 392  # how far the blades reach
OPENING = 104  # the opening in the middle (its corners)
BOW = 0.16  # how much the seams between the blades curve, of their length


def point(radius, degrees):
    """A point at `radius` from the middle, `degrees` clockwise from straight up."""
    rad = math.radians(degrees)
    return (CENTER + radius * math.sin(rad), CENTER - radius * math.cos(rad))


def to_rim(start, degrees):
    """Where a ray from `start`, `degrees` clockwise from straight up, meets the rim."""
    dx, dy = math.sin(math.radians(degrees)), -math.cos(math.radians(degrees))
    hx, hy = start[0] - CENTER, start[1] - CENTER
    b = hx * dx + hy * dy
    along = -b + math.sqrt(b * b - (hx * hx + hy * hy) + OUTER**2)
    return (start[0] + along * dx, start[1] + along * dy)


def seam(index):
    """The curved seam between two blades: from a corner of the opening, on in the direction of
    the opening's side that ends there, out to the rim. Both blades use the same one, so they
    meet exactly, without overlapping and without a gap."""
    a = index * 60
    corner = point(OPENING, a)
    rim = to_rim(corner, a + 60)
    mx, my = (corner[0] + rim[0]) / 2, (corner[1] + rim[1]) / 2
    dx, dy = rim[0] - corner[0], rim[1] - corner[1]
    control = (mx - dy * BOW, my + dx * BOW)
    return corner, control, rim


def blade_path(index):
    """One blade, as in a camera's aperture: along a side of the opening, out along the next
    seam, round the rim, and back in along its own seam. Six of them fill the circle and leave
    the opening free."""
    corner, control, rim = seam(index)
    next_corner, next_control, next_rim = seam(index + 1)
    return (
        f"M {corner[0]:.1f},{corner[1]:.1f} "
        f"L {next_corner[0]:.1f},{next_corner[1]:.1f} "
        f"Q {next_control[0]:.1f},{next_control[1]:.1f} {next_rim[0]:.1f},{next_rim[1]:.1f} "
        f"A {OUTER} {OUTER} 0 0 0 {rim[0]:.1f},{rim[1]:.1f} "
        f"Q {control[0]:.1f},{control[1]:.1f} {corner[0]:.1f},{corner[1]:.1f} Z"
    )


def blade_svg(index, light, deep):
    """A blade in its colour, deep at the opening and lighter towards the rim (the same for all
    six, as if light fell through the aperture)."""
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="{SIZE}" height="{SIZE}">
  <defs>
    <radialGradient id="g" gradientUnits="userSpaceOnUse" cx="{CENTER}" cy="{CENTER}" r="{OUTER}">
      <stop offset="0.25" stop-color="{deep}"/>
      <stop offset="1" stop-color="{light}"/>
    </radialGradient>
  </defs>
  <path d="{blade_path(index)}" fill="url(#g)"/>
</svg>
"""


def icon_json():
    blades = [
        {
            "glass": True,
            "hidden": False,
            "image-name": f"blade-{name}.svg",
            "name": f"blade {name}",
            "position": {"scale": 1, "translation-in-points": [0, 0]},
        }
        for name, _, _ in BLADES
    ]
    return {
        "fill": {"automatic-gradient": "extended-srgb:1.00000,1.00000,1.00000,1.00000"},
        "groups": [
            {
                "layers": blades,
                "name": "Aperture",
                "shadow": {"kind": "layer-color", "opacity": 0.4},
                # Not see-through: the blades are solid, only their edges catch the light.
                "translucency": {"enabled": False, "value": 0},
            }
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }


def preview_svg():
    """Everything flat, to look at without Xcode (the glass is the system's)."""
    parts = []
    for i, (_, light, deep) in enumerate(BLADES):
        body = blade_svg(i, light, deep).split(">", 1)[1].rsplit("</svg>", 1)[0]
        body = body.replace('id="g"', 'id="g%d"' % i).replace("url(#g)", "url(#g%d)" % i)
        parts.append(body)
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIZE} {SIZE}" width="{SIZE}" height="{SIZE}">
  <defs><clipPath id="icon"><rect width="{SIZE}" height="{SIZE}" rx="230"/></clipPath>
  <radialGradient id="bg" cx="0.5" cy="0.35" r="0.8"><stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#ECEEF2"/></radialGradient></defs>
  <g clip-path="url(#icon)">
    <rect width="{SIZE}" height="{SIZE}" fill="url(#bg)"/>
    {"".join(parts)}
  </g>
</svg>
"""


def main():
    if ICON.exists():
        shutil.rmtree(ICON)
    assets = ICON / "Assets"
    assets.mkdir(parents=True)
    for index, (name, light, deep) in enumerate(BLADES):
        (assets / f"blade-{name}.svg").write_text(blade_svg(index, light, deep))
    (ICON / "icon.json").write_text(json.dumps(icon_json(), indent=2) + "\n")
    (HERE / "preview.svg").write_text(preview_svg())
    print(f"wrote {ICON.relative_to(HERE.parent)} and Icon/preview.svg")


if __name__ == "__main__":
    main()
