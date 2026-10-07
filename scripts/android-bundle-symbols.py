#!/usr/bin/env python3
"""Verify embedded Rust symbols and extract a Play-ready native symbols ZIP."""
import sys
import zipfile
from pathlib import Path

bundle, output = map(Path, sys.argv[1:])
prefix = "BUNDLE-METADATA/com.android.tools.build.debugsymbols/"
with zipfile.ZipFile(bundle) as archive:
    names = archive.namelist()
    for abi in ("arm64-v8a", "x86_64"):
        name = f"{prefix}{abi}/libtokenstat_ffi.so.dbg"
        if name not in names or not archive.getinfo(name).file_size:
            raise SystemExit(f"error: App Bundle is missing native symbols for {abi}")
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as symbols:
        for name in names:
            if name.startswith(prefix) and name.endswith((".dbg", ".sym")):
                symbols.writestr(name[len(prefix):], archive.read(name))
