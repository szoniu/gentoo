#!/usr/bin/env python3
"""Generate a dark gradient background PNG for GRUB theme.

Creates a 1920x1080 vertical gradient from dark navy (#0d0d1a)
to dark purple (#1a0d2e) using only Python standard library.
Output is highly compressible (~30-50 KB) because each row is uniform.
"""
import struct
import sys
import zlib

W, H = 1920, 1080

# Gradient colors: top = dark navy, bottom = dark purple
TOP = (13, 13, 26)
BOT = (26, 13, 46)

rows = []
for y in range(H):
    t = y / (H - 1) if H > 1 else 0
    r = int(TOP[0] + (BOT[0] - TOP[0]) * t)
    g = int(TOP[1] + (BOT[1] - TOP[1]) * t)
    b = int(TOP[2] + (BOT[2] - TOP[2]) * t)
    # Filter byte 0 (None) + row pixels
    rows.append(b'\x00' + bytes([r, g, b]) * W)

raw = b''.join(rows)


def chunk(ctype, data):
    c = ctype + data
    return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xFFFFFFFF)


ihdr = struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)  # 8-bit RGB
idat = zlib.compress(raw, 9)

out = sys.argv[1] if len(sys.argv) > 1 else 'background.png'
with open(out, 'wb') as f:
    f.write(b'\x89PNG\r\n\x1a\n')
    f.write(chunk(b'IHDR', ihdr))
    f.write(chunk(b'IDAT', idat))
    f.write(chunk(b'IEND', b''))
