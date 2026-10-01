# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Source checks for the boundary between translated copy and stable values."""
import re

TEXT_CALL = r'L10n\.(?:text|Text)\s*\(\s*"([^"\n]+)"'
IDENTIFIERS = r'id|scope|autonomy|backend|kind|column|command|method|route|identifier|addingIn|_inspectorTab|_filter|Arguments'
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
    r'\bFontFamily\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:\{[^}]*\}\s*)?=\s*new\s*\(\s*',
    r'\bGetHeader\(\s*',
    r'\bCreateWebResourceResponse\([^,\n]*,\s*[^,\n]*,\s*',
)

# Ignore delimiters inside strings and comments when limiting checks to the
# arguments of one call. A translated error after a Path.Combine is still UI
# copy, so a regex spanning the rest of the statement would overreach.
CALL_TOKENS = re.compile(r'''//[^\n]*|/\*.*?\*/|@"(?:[^"]|"")*"|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[()]''', re.S)


def call_end(source, opening):
    depth = 0
    for token in CALL_TOKENS.finditer(source, opening):
        if token[0] == "(":
            depth += 1
        elif token[0] == ")":
            depth -= 1
            if depth == 0:
                return token.start()
    return len(source)


def technical_uses(source):
    """Yield resource references used for matching, request fields, or IDs."""
    for context in TECHNICAL_CONTEXTS:
        for match in re.finditer(r'(?:' + context + r')' + TEXT_CALL, source):
            yield match.start(), match[1]
    # Filesystem segments, font families and URI references are resolved by
    # the platform. A translated word there cannot identify the shipped asset.
    for call in re.finditer(r'\b(?:Path\.(?:Combine|Join)|new\s+(?:FontFamily|Uri))\s*\(', source):
        end = call_end(source, call.end() - 1)
        for match in re.finditer(TEXT_CALL, source[call.end():end]):
            yield call.end() + match.start(), match[1]
    # The value of an Android segmented choice is sent to the host; its second
    # element is the display label. Other pairs can be display-only tables.
    for choices in re.finditer(r'ChatSegmented\(\s*options\s*=\s*listOf\((.*?)\),\s*selected\s*=', source, re.S):
        for match in re.finditer(TEXT_CALL + r'\s*\)\s+to\b', choices[1]):
            yield choices.start(1) + match.start(), match[1]
    # Home saves these values to disk and uses them to look up rendered cards.
    for identifiers in re.finditer(r'\b_(?:sectionOrder|hiddenSections)\s*=\s*\[([^;]+)\]', source):
        for match in re.finditer(TEXT_CALL, identifiers[1]):
            yield identifiers.start(1) + match.start(), match[1]
    # An extension list is part of matching a command, even when the actual
    # EndsWith call takes a lambda parameter rather than a resource directly.
    for extensions in re.finditer(r'new\s*\[\]\s*\{(.*?)\}\s*\.Any\(\s*(\w+)\s*=>\s*[^;\n]*?\.(?:EndsWith|StartsWith)\(\s*\2', source, re.S):
        for match in re.finditer(TEXT_CALL, extensions[1]):
            yield extensions.start(1) + match.start(), match[1]
