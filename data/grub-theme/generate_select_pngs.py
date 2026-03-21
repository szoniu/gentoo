#!/usr/bin/env python3
"""Generate 9-slice PNG images for GRUB theme selected item highlight.

Creates select_c.png (center), select_n/s/e/w.png (edges),
select_ne/nw/se/sw.png (corners) — small solid-color PNGs.
Uses only Python standard library.
"""
import os
import struct
import sys
import zlib

ACCENT = (84, 198, 198)  # #54c6c6 — cyan accent
BG = (20, 30, 50)  # dark blue-ish background for selection


def make_png(width, height, color, alpha=255):
    """Create a minimal RGBA PNG."""
    def chunk(ctype, data):
        c = ctype + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    r, g, b = color
    row = b'\x00' + bytes([r, g, b, alpha]) * width
    raw = row * height
    idat = zlib.compress(raw, 9)

    data = b'\x89PNG\r\n\x1a\n'
    data += chunk(b'IHDR', ihdr)
    data += chunk(b'IDAT', idat)
    data += chunk(b'IEND', b'')
    return data


outdir = sys.argv[1] if len(sys.argv) > 1 else '.'

# Center: semi-transparent dark bg
center = make_png(1, 1, BG, 180)

# Edges: thin accent lines (2px wide/tall)
edge_h = make_png(1, 2, ACCENT, 200)  # horizontal edge (n, s)
edge_v = make_png(2, 1, ACCENT, 200)  # vertical edge (e, w)

# Corners: small 2x2 accent squares
corner = make_png(2, 2, ACCENT, 200)

files = {
    'select_c.png': center,
    'select_n.png': edge_h,
    'select_s.png': edge_h,
    'select_e.png': edge_v,
    'select_w.png': edge_v,
    'select_ne.png': corner,
    'select_nw.png': corner,
    'select_se.png': corner,
    'select_sw.png': corner,
}

for name, data in files.items():
    path = os.path.join(outdir, name)
    with open(path, 'wb') as f:
        f.write(data)
