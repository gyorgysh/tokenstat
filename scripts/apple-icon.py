# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Validate the PNG metadata Apple checks for store icons, without image codecs."""
import struct


def validate_store_icon(data, size=None):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Store icon is not a PNG")
    offset = 8
    header = None
    while offset + 12 <= len(data):
        count = struct.unpack_from(">I", data, offset)[0]
        end = offset + 12 + count
        if end > len(data):
            raise ValueError("Store icon PNG is truncated")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + count]
        if kind == b"IHDR":
            if count != 13:
                raise ValueError("Store icon PNG has an invalid header")
            width, height, _, color, _, _, _ = struct.unpack(">IIBBBBB", payload)
            if color in (4, 6):
                raise ValueError("Store icon must not contain an alpha channel")
            header = (width, height)
        if kind == b"tRNS":
            raise ValueError("Store icon must not contain transparency")
        if kind == b"IEND":
            break
        offset = end
    if header is None or size is not None and header != (size, size):
        raise ValueError("Store icon has the wrong dimensions")
