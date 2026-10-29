#!/usr/bin/env python3
"""Make the app icons from the title's own art.

The source is a cover image when one is given (the square below a PSN
store banner is cut out), otherwise the package's ICON0.PNG laid over its
blurred PIC1.PNG. Writes into <out dir>:
  Assets-ios.xcassets   one 1024x1024 icon (iPad, iPhone)
  Assets-tvos.xcassets  a two-layer parallax icon (blurred art behind, the
                        square in front) and the top shelf images
  AppIcon.icns          for the Mac app
  icon1024.png          the square itself

Usage: make_icons.py <game dir with ICON0.PNG/PIC1.PNG> <out dir> [--cover IMAGE]
"""
import argparse
import json
import os
import subprocess
import tempfile
from pathlib import Path

from PIL import Image, ImageEnhance, ImageFilter

INFO = {"author": "xcode", "version": 1}


def square_from_cover(path):
    im = Image.open(path).convert('RGB')
    w, h = im.size
    top = int(h * 0.09) if h > w else 0          # a PSN store banner across the top
    side = min(w, h - top)
    return im.crop(((w - side) // 2, top + (h - top - side) // 2,
                    (w - side) // 2 + side, top + (h - top - side) // 2 + side)), \
        im.crop((0, top, w, h))


def square_from_package(game):
    bg = Image.open(game / 'PIC1.PNG').convert('RGB')
    logo = Image.open(game / 'ICON0.PNG').convert('RGBA')
    side = min(bg.size)
    sq = bg.crop(((bg.width - side) // 2, (bg.height - side) // 2,
                  (bg.width + side) // 2, (bg.height + side) // 2)).resize((1024, 1024), Image.LANCZOS)
    sq = ImageEnhance.Brightness(sq.filter(ImageFilter.GaussianBlur(6))).enhance(0.8).convert('RGBA')
    lw = 920
    logo = logo.resize((lw, int(logo.height * lw / logo.width)), Image.LANCZOS)
    sq.alpha_composite(logo, ((1024 - logo.width) // 2, (1024 - logo.height) // 2))
    return sq.convert('RGB'), bg


def build(square, art, out):
    out.mkdir(parents=True, exist_ok=True)
    square = square.resize((1024, 1024), Image.LANCZOS)
    square.save(out / 'icon1024.png')

    def back(w, h):
        a = art.copy()
        r = max(w / a.width, h / a.height)
        a = a.resize((int(a.width * r) + 1, int(a.height * r) + 1), Image.LANCZOS)
        x, y = (a.width - w) // 2, (a.height - h) // 2
        a = a.crop((x, y, x + w, y + h)).filter(ImageFilter.GaussianBlur(max(w, h) / 60))
        return ImageEnhance.Brightness(a).enhance(0.55)

    def front(w, h, frac):
        f = Image.new('RGBA', (w, h), (0, 0, 0, 0))
        s = int(h * frac)
        f.paste(square.resize((s, s), Image.LANCZOS), ((w - s) // 2, (h - s) // 2))
        return f

    def flat(w, h, frac):
        b = back(w, h).convert('RGBA')
        b.alpha_composite(front(w, h, frac))
        return b.convert('RGB')

    def write(path, obj):
        path.write_text(json.dumps(obj))

    x = out / 'Assets-ios.xcassets'
    (x / 'AppIcon.appiconset').mkdir(parents=True, exist_ok=True)
    write(x / 'Contents.json', {"info": INFO})
    square.save(x / 'AppIcon.appiconset' / 'icon1024.png')
    write(x / 'AppIcon.appiconset' / 'Contents.json',
          {"images": [{"filename": "icon1024.png", "idiom": "universal",
                       "platform": "ios", "size": "1024x1024"}], "info": INFO})

    t = out / 'Assets-tvos.xcassets'
    b = t / 'App Icon & Top Shelf Image.brandassets'
    b.mkdir(parents=True, exist_ok=True)
    write(t / 'Contents.json', {"info": INFO})

    def stack(name, w, h, scales):
        d = b / f'{name}.imagestack'
        layers = []
        for lname, mk in (('Front', lambda W, H: front(W, H, 0.96)), ('Back', back)):
            cd = d / f'{lname}.imagestacklayer' / 'Content.imageset'
            cd.mkdir(parents=True, exist_ok=True)
            imgs = []
            for sc in scales:
                fn = f'{lname.lower()}@{sc}x.png'
                mk(w * sc, h * sc).save(cd / fn)
                imgs.append({"filename": fn, "idiom": "tv", "scale": f"{sc}x"})
            write(cd / 'Contents.json', {"images": imgs, "info": INFO})
            write(d / f'{lname}.imagestacklayer' / 'Contents.json', {"info": INFO})
            layers.append({"filename": f"{lname}.imagestacklayer"})
        write(d / 'Contents.json', {"layers": layers, "info": INFO})

    def shelf(name, w, h):
        d = b / f'{name}.imageset'
        d.mkdir(parents=True, exist_ok=True)
        imgs = []
        for sc in (1, 2):
            fn = f'shelf@{sc}x.png'
            flat(w * sc, h * sc, 0.92).save(d / fn)
            imgs.append({"filename": fn, "idiom": "tv", "scale": f"{sc}x"})
        write(d / 'Contents.json', {"images": imgs, "info": INFO})

    stack('App Icon', 400, 240, (1, 2))
    stack('App Icon - App Store', 1280, 768, (1,))
    shelf('Top Shelf Image', 1920, 720)
    shelf('Top Shelf Image Wide', 2320, 720)
    write(b / 'Contents.json', {"assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv",
         "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv",
         "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"},
    ], "info": INFO})

    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / 'AppIcon.iconset'
        iconset.mkdir()
        for s in (16, 32, 128, 256, 512):
            square.resize((s, s), Image.LANCZOS).save(iconset / f'icon_{s}x{s}.png')
            square.resize((s * 2, s * 2), Image.LANCZOS).save(iconset / f'icon_{s}x{s}@2x.png')
        subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(out / 'AppIcon.icns')], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('game', type=Path)
    ap.add_argument('out', type=Path)
    ap.add_argument('--cover', type=Path)
    a = ap.parse_args()
    if a.cover and a.cover.is_file():
        square, art = square_from_cover(a.cover)
    else:
        square, art = square_from_package(a.game)
    build(square, art, a.out)
    print(f'icons -> {a.out}')


if __name__ == '__main__':
    main()
