# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Validate the PNG metadata Apple checks for store icons, without image codecs."""
import struct
import zlib


def validate_store_icon(data, size=None):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Store icon is not a PNG")
    offset = 8
    header = None
    finished = False
    while offset + 12 <= len(data):
        count = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + count
        if end > len(data):
            raise ValueError("Store icon PNG is truncated")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + count]
        crc = struct.unpack_from(">I", data, offset + 8 + count)[0]
        if zlib.crc32(kind + payload) != crc:
            raise ValueError("Store icon PNG has a corrupt chunk")
        # Apple's PNG optimizer can prepend CgBI in compiled bundle icons.
        if header is None and kind != b"IHDR" and not (offset == 8 and kind == b"CgBI"):
            raise ValueError("Store icon PNG must start with a header")
        if kind == b"IHDR":
            if count != 13 or header is not None:
                raise ValueError("Store icon PNG has an invalid header")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if color in (4, 6):
                raise ValueError("Store icon must not contain an alpha channel")
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8)}
            if width == 0 or height == 0 or depth not in depths.get(color, ()) or compression != 0 or filtering != 0 or interlace not in (0, 1):
                raise ValueError("Store icon PNG has an invalid header")
            header = (width, height)
        if kind == b"tRNS":
            raise ValueError("Store icon must not contain transparency")
        if kind == b"IEND":
            if count != 0 or end != len(data):
                raise ValueError("Store icon PNG has an invalid end")
            finished = True
            break
        offset = end
    if not finished:
        raise ValueError("Store icon PNG is truncated")
    if header is None or size is not None and header != (size, size):
        raise ValueError("Store icon has the wrong dimensions")
