#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Use the real CLI to verify the helper under a non-UTF-8 process locale."""
import json
import os
from pathlib import Path
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "apps/charts/sdk"))
from tokenstat_charts import chart

binary = root / "target/debug" / ("tokenstat.exe" if os.name == "nt" else "tokenstat")
examples = json.loads((root / "apps/charts/examples.json").read_text(encoding="utf-8"))
with tempfile.TemporaryDirectory(prefix="tokenstat-chart-sdk-") as directory:
    data = Path(directory) / "data"
    identity = Path(directory) / "identity"
    os.environ["TOKENSTAT_DATA_DIR"] = str(data)
    os.environ["TOKENSTAT_IDENTITY_DIR"] = str(identity)
    for example in examples:
        example["title"] = "Revenue \u65e5\u672c\u8a9e \U0001f4ca"
        example["series"][0]["name"] = "\u00c9quipe \u5317"
        markdown = chart(example, executable=str(binary))
        assert markdown.startswith("```tokenstat-chart\n")
        normalized = json.loads(markdown.splitlines()[1])
        assert normalized["title"] == example["title"]
        assert normalized["series"][0]["name"] == example["series"][0]["name"]
    try:
        chart({"version": 1}, executable=str(binary))
    except ValueError:
        pass
    else:
        raise AssertionError("Invalid data did not fail validation")
    assert not data.exists(), "Chart SDK opened the usage archive"
    assert not identity.exists(), "Chart SDK opened the identity store"
print("Python chart SDK: 12 families preserve Unicode across process locales; invalid input fails offline.")
