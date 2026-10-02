#!/usr/bin/env python3
"""Writes a solid RAR 4 archive of stored files: mkrar4.py out.rar name=path ...
(the files after the first are marked solid, which the system libarchive refuses)."""
import os, struct, sys, time, zlib


def crc16(data):
    return zlib.crc32(data) & 0xFFFF


def dos_time(seconds):
    t = time.localtime(seconds)
    return (t.tm_year - 1980) << 25 | t.tm_mon << 21 | t.tm_mday << 16 | t.tm_hour << 11 | t.tm_min << 5 | t.tm_sec // 2


out, specs = sys.argv[1], sys.argv[2:]
data = b"Rar!\x1a\x07\x00"
body = struct.pack("<BHH", 0x73, 0x0008, 13) + b"\x00" * 6  # archive header, MHD_SOLID
data += struct.pack("<H", crc16(body)) + body
for index, spec in enumerate(specs):
    name, path = spec.split("=", 1)
    content = open(path, "rb").read()
    encoded = name.encode()
    flags = 0x8000 | (0x0010 if index else 0)  # LONG_BLOCK, LHD_SOLID after the first
    rest = struct.pack("<BHHIIBIIBBHI", 0x74, flags, 32 + len(encoded), len(content), len(content), 3,
                       zlib.crc32(content), dos_time(os.path.getmtime(path)), 29, 0x30, len(encoded), 0o100644)
    data += struct.pack("<H", crc16(rest + encoded)) + rest + encoded + content
data += b"\xc4\x3d\x7b\x00\x40\x07\x00"
open(out, "wb").write(data)
