#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Bake real font outlines at each requested weight; do not rewrite fvar defaults.

GPUI 0.2.2's memory font selection does not instantiate a variable weight on
macOS. These faces also give the Linux font backend the same concrete inputs.
The original fonts remain authoritative. Outputs belong only in Cargo OUT_DIR.
"""

import argparse
from pathlib import Path

import fontTools
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont


def prepare(root: Path, output: Path) -> None:
    if fontTools.__version__ != "4.68.0":
        raise RuntimeError("Use scripts/prepare-linux-fonts.sh to install the pinned build tool")
    output.mkdir(parents=True, exist_ok=True)
    rust = ["vec!["]
    for family in ["Manrope", "JetBrainsMono"]:
        source = root / "apps/mac/Resources/Fonts" / f"{family}-Variable.ttf"
        for weight in [400, 500, 600, 700]:
            with TTFont(source, recalcTimestamp=False) as variable:
                instance = instantiateVariableFont(variable, {"wght": weight})
                instance.recalcTimestamp = False
                # Some named weights are absent from the bundled STAT table.
                # Name every face explicitly while retaining copyright/licence records.
                style = {400: "Regular", 500: "Medium", 600: "SemiBold", 700: "Bold"}[weight]
                display = "JetBrains Mono" if family == "JetBrainsMono" else family
                names = {1: display, 2: style, 3: f"{family}-{style}-tokenstat",
                         4: f"{display} {style}", 6: f"{family}-{style}", 16: display, 17: style}
                table = instance["name"]
                table.names = [n for n in table.names if n.nameID not in names]
                for name_id, value in names.items():
                    table.setName(value, name_id, 3, 1, 0x409)
                    table.setName(value, name_id, 1, 0, 0)
                instance["head"].macStyle &= ~1
                instance["OS/2"].fsSelection &= ~((1 << 5) | (1 << 6))
                if weight == 700:
                    instance["head"].macStyle |= 1
                    instance["OS/2"].fsSelection |= 1 << 5
                elif weight == 400:
                    instance["OS/2"].fsSelection |= 1 << 6
                if "fvar" in instance or instance["OS/2"].usWeightClass != weight:
                    raise RuntimeError(f"{family} {weight}: incomplete weight instancing")
                filename = f"{family}-{weight}.ttf"
                instance.save(output / filename)
                # Reopen the actual output, rather than relying only on the in-memory face.
                with TTFont(output / filename) as check:
                    if "fvar" in check or check["OS/2"].usWeightClass != weight:
                        raise RuntimeError(f"{filename}: output verification failed")
                rust.append(f'    Cow::Borrowed(include_bytes!("fonts/{filename}") as &\'static [u8]),')
    rust.append("]")
    (output.parent / "embedded_fonts.rs").write_text("\n".join(rust) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    prepare(Path(__file__).resolve().parent.parent, arguments.output)
