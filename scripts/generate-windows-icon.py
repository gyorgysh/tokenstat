#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
#
# Build apps/windows/Assets/tokenstat.ico from the Mac app icon PNGs.
# Windows ICO since Vista can embed PNG images. We keep 16, 32, 48 and 256.

from __future__ import annotations

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "apps/mac/Design/AppIcon/tokenstat-icon-light-512.png"
DEST_DIR = ROOT / "apps/windows/Assets"
SIZES = (16, 32, 48, 256)


def sips_resize(src: Path, dest: Path, size: int) -> None:
    subprocess.run(
        ["sips", "-z", str(size), str(size), str(src), "--out", str(dest)],
        check=True,
        capture_output=True,
    )


def pack_ico(pngs: list[tuple[int, bytes]], dest: Path) -> None:
    count = len(pngs)
    offset = 6 + 16 * count
    header = struct.pack("<HHH", 0, 1, count)
    entries = bytearray()
    blobs = bytearray()
    for size, data in pngs:
        width = 0 if size >= 256 else size
        height = width
        entries += struct.pack("<BBBBHHII", width, height, 0, 0, 1, 32, len(data), offset)
        blobs += data
        offset += len(data)
    dest.write_bytes(header + entries + blobs)


def main() -> int:
    if not SRC.is_file():
        print(f"error: missing source icon {SRC}", file=sys.stderr)
        return 1
    DEST_DIR.mkdir(parents=True, exist_ok=True)
    pngs: list[tuple[int, bytes]] = []
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        for size in SIZES:
            out = tmp_path / f"icon-{size}.png"
            sips_resize(SRC, out, size)
            pngs.append((size, out.read_bytes()))
    ico = DEST_DIR / "tokenstat.ico"
    pack_ico(pngs, ico)
    # In-app About mark. Same light tile as the ICO.
    about = DEST_DIR / "tokenstat.png"
    about.write_bytes(
        (ROOT / "apps/mac/Design/AppIcon/tokenstat-icon-light-256.png").read_bytes()
    )
    print(f"wrote {ico} ({ico.stat().st_size} bytes) and {about}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
