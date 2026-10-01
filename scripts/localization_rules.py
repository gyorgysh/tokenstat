# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Source checks for the boundary between translated copy and stable values."""
import re

TEXT_CALL = r'L10n\.(?:text|Text)\s*\(\s*"([^"\n]+)"'
IDENTIFIERS = r'id|scope|autonomy|backend|kind|column|command|method|route|identifier|addingIn|_inspectorTab|_filter'
TECHNICAL_CONTEXTS = (
    r'\bcase\s+|(?:==|!=|~=)\s*',
    r'[A-Za-z0-9_.?$]*(?:Contains|contains|StartsWith|startsWith|EndsWith|endsWith|hasPrefix|hasSuffix|Equals|equals)\(\s*',
    rf'\b(?:{IDENTIFIERS})\s*(?:=|:)\s*',
    rf'\b(?:{IDENTIFIERS})\s*:\s*[A-Za-z_][A-Za-z0-9_<>?.\[\] ]*\s*=\s*',
    r'\bFormat\.(?:Text|Number|Long|Flag)\([^,\n]+,\s*',
    r'\b(?:Format\.)?Text\([^,\n]+,\s*"(?:scope|autonomy|kind|column|command|method|route)"\s*,\s*',
    r'\bAutonomyPill\([^\n;]+?,\s*',
    r'\bShowCompanion\(\s*',
    r'\.ToString\(\s*|\bSimpleDateFormat\(\s*|\bDateTimeFormatter\.ofPattern\(\s*',
)


def technical_uses(source):
    """Yield resource references used for matching, request fields, or IDs."""
    for context in TECHNICAL_CONTEXTS:
        for match in re.finditer(r'(?:' + context + r')' + TEXT_CALL, source):
            yield match.start(), match[1]
    # The value of an Android segmented choice is sent to the host; its second
    # element is the display label. Other pairs can be display-only tables.
    for choices in re.finditer(r'ChatSegmented\(\s*options\s*=\s*listOf\((.*?)\),\s*selected\s*=', source, re.S):
        for match in re.finditer(TEXT_CALL + r'\s*\)\s+to\b', choices[1]):
            yield choices.start(1) + match.start(), match[1]
    # Home saves these values to disk and uses them to look up rendered cards.
    for identifiers in re.finditer(r'\b_(?:sectionOrder|hiddenSections)\s*=\s*\[([^;]+)\]', source):
        for match in re.finditer(TEXT_CALL, identifiers[1]):
            yield identifiers.start(1) + match.start(), match[1]
