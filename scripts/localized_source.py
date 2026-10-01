# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Resolve static Apple copy for source checks that inspect visible labels."""
import json
import re
from pathlib import Path

_root = Path(__file__).resolve().parent.parent
_strings = {}
for _table in ("common", "apple"):
    _strings.update(json.loads((_root / "apps/localization/en" / f"{_table}.json").read_text()))


def read_source(path):
    source = Path(path).read_text()
    return re.sub(
        r'L10n\.text\("([^"]+)"\)',
        lambda match: json.dumps(_strings[match[1]], ensure_ascii=False),
        source,
    )
