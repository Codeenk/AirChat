#!/usr/bin/env python3
"""Generate Android + iOS launcher icons from assets/icon/app_icon.png.

Usage:
    pip install pillow
    python3 tool/generate_app_icons.py

Source image must be square (any size >= 1024px recommended).
"""
import os
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "assets", "icon", "app_icon.png")
ANDROID_RES = os.path.join(ROOT, "android", "app", "src", "main", "res")

# density -> launcher size (48dp baseline) / adaptive foreground size (108dp)
ANDROID_DENSITIES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}
ADAPTIVE_DENSITIES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}

# Safe zone: logo occupies ~58% of the adaptive foreground canvas so it is
# never clipped by the circular/squircle mask.
ADAPTIVE_LOGO_FRACTION = 0.58

IOS_SIZES = [20, 29, 40, 60, 76, 83.5, 1024]
BACKGROUND_RGB = (14, 14, 18)  # near-black matching the source artwork


def load_source() -> Image.Image:
    img = Image.open(SRC).convert("RGBA")
    if img.width != img.height:
        side = min(img.width, img.height)
        left = (img.width - side) // 2
        top = (img.height - side) // 2
        img = img.crop((left, top, left + side, top + side))
    return img


def write_png(img: Image.Image, path: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path, "PNG")
    print(f"  wrote {os.path.relpath(path, ROOT)}")


def generate_legacy(src: Image.Image) -> None:
    print("Android legacy launcher icons:")
    for density, size in ANDROID_DENSITIES.items():
        out = src.resize((size, size), Image.LANCZOS)
        # Legacy icons are opaque squares; composite over brand background.
        bg = Image.new("RGBA", (size, size), BACKGROUND_RGB + (255,))
        bg.alpha_composite(out)
        write_png(bg.convert("RGBA"), os.path.join(
            ANDROID_RES, f"mipmap-{density}", "ic_launcher.png"))


def generate_adaptive(src: Image.Image) -> None:
    print("Android adaptive foreground layers:")
    for density, size in ADAPTIVE_DENSITIES.items():
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        logo_side = round(size * ADAPTIVE_LOGO_FRACTION)
        logo = src.resize((logo_side, logo_side), Image.LANCZOS)
        offset = ((size - logo_side) // 2, (size - logo_side) // 2)
        canvas.alpha_composite(logo, offset)
        write_png(canvas, os.path.join(
            ANDROID_RES, f"mipmap-{density}", "ic_launcher_foreground.png"))

    xml = """<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/ic_launcher_background"/>
    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
"""
    path = os.path.join(ANDROID_RES, "mipmap-anydpi-v26", "ic_launcher.xml")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(xml)
    print(f"  wrote {os.path.relpath(path, ROOT)}")


def generate_ios(src: Image.Image) -> None:
    appiconset = os.path.join(
        ROOT, "ios", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    if not os.path.isdir(appiconset):
        print("iOS target not found — skipping.")
        return
    print("iOS AppIcon:")
    for size in IOS_SIZES:
        px = int(round(size * 2))  # @2x
        out = src.resize((px, px), Image.LANCZOS)
        bg = Image.new("RGBA", (px, px), BACKGROUND_RGB + (255,))
        bg.alpha_composite(out)
        write_png(bg, os.path.join(appiconset, f"Icon-App-{size}x{size}@2x.png"))
    one = src.resize((1024, 1024), Image.LANCZOS).convert("RGB")
    write_png(one, os.path.join(appiconset, "Icon-App-1024x1024@1x.png"))


def main() -> None:
    src = load_source()
    generate_legacy(src)
    generate_adaptive(src)
    generate_ios(src)
    print("Done.")


if __name__ == "__main__":
    main()
