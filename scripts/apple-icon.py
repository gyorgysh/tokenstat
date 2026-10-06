# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Validate opaque store icons, including their compressed image stream."""
import struct
import zlib


def validate_store_icon(data, size=None):
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("Store icon is not a PNG")
    offset = 8
    header = None
    finished = False
    optimized = False
    compressed = bytearray()
    palette = False
    image_ended = False
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
        if kind == b"CgBI":
            optimized = True
        if kind == b"IHDR":
            if count != 13 or header is not None:
                raise ValueError("Store icon PNG has an invalid header")
            width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload)
            if color in (4, 6):
                raise ValueError("Store icon must not contain an alpha channel")
            depths = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8)}
            if not 0 < width <= 8192 or not 0 < height <= 8192 or depth not in depths.get(color, ()) or compression != 0 or filtering != 0 or interlace not in (0, 1):
                raise ValueError("Store icon PNG has an invalid header")
            header = (width, height)
        if kind == b"PLTE":
            if count == 0 or count > 768 or count % 3:
                raise ValueError("Store icon PNG has an invalid palette")
            palette = True
        if kind == b"IDAT":
            if image_ended:
                raise ValueError("Store icon PNG has noncontiguous image data")
            compressed.extend(payload)
        elif compressed:
            image_ended = True
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
    if not compressed or color == 3 and not palette:
        raise ValueError("Store icon PNG has no image data or palette")
    channels = 3 if color == 2 else 1
    passes = [(0, 0, 1, 1)] if interlace == 0 else [
        (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
        (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
    rows = []
    for start_x, start_y, step_x, step_y in passes:
        columns = max(0, (width - start_x + step_x - 1) // step_x)
        lines = max(0, (height - start_y + step_y - 1) // step_y)
        if columns and lines:
            rows.extend([1 + (columns * channels * depth + 7) // 8] * lines)
    expected = sum(rows)
    try:
        decoder = zlib.decompressobj(-15 if optimized else 15)
        decoded = decoder.decompress(compressed, expected + 1)
        if len(decoded) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
            raise ValueError("Store icon PNG has an invalid image stream")
    except zlib.error as error:
        raise ValueError("Store icon PNG has an unreadable image stream") from error
    offset = 0
    for row_size in rows:
        if decoded[offset] > 4:
            raise ValueError("Store icon PNG has an invalid row filter")
        offset += row_size
