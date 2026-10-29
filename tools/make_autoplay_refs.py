#!/usr/bin/env python3
"""Pack the playtest's reference screens for the on-device autoplay.

tests/refs/<screen>/*.png (cut from the user's own game by playtest.py
--calibrate) become 64x36 greyscale thumbnails made exactly as playtest.py
makes them, in one file the app bundle carries (PAD_AUTOPLAY in cellPad.c,
the classifier in the Metal backend):
  "APRF", u32 count, then count x (u8 screen, 64*36 u8 pixels)
Screens: intro 0, title 1, menu 2, level 3, pause 4, gameover 5.

Usage: make_autoplay_refs.py <out file>
"""
import struct
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SCREENS = ['intro', 'title', 'menu', 'level', 'pause', 'gameover']


def main():
    out = []
    for sid, name in enumerate(SCREENS):
        for p in sorted((ROOT / 'tests' / 'refs' / name).glob('*.png')):
            img = Image.open(p).convert('L').resize((64, 36), Image.BILINEAR)
            out.append(struct.pack('B', sid) + img.tobytes())
    data = b'APRF' + struct.pack('<I', len(out)) + b''.join(out)
    Path(sys.argv[1]).write_bytes(data)
    print(f'{len(out)} reference screens -> {sys.argv[1]}')


if __name__ == '__main__':
    main()
