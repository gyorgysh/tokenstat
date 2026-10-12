# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Evaluate compound SPDX expressions using the repository dependency policy."""
import re

BLOCKING = ("GPL", "AGPL", "LGPL", "EUPL", "CDDL", "OSL", "SSPL", "CC-BY-SA")
TOKEN = re.compile(r"\s*([A-Za-z0-9][A-Za-z0-9.+:-]*|[()])")


def clean_license(expression):
    # Older Cargo manifests used a slash for dual licensing.
    expression = expression.replace("/", " OR ")
    tokens = []
    cursor = 0
    while cursor < len(expression):
        if not expression[cursor:].strip():
            break
        match = TOKEN.match(expression, cursor)
        if not match:
            return False
        tokens.append(match[1])
        cursor = match.end()
    index = 0

    def take(value):
        nonlocal index
        if index < len(tokens) and tokens[index] == value:
            index += 1
            return True
        return False

    def identifier():
        nonlocal index
        if index == len(tokens) or tokens[index] in {"(", ")", "AND", "OR", "WITH"}:
            raise ValueError("expected licence identifier")
        value = tokens[index]
        index += 1
        return value

    def factor():
        if take("("):
            value = either()
            if not take(")"):
                raise ValueError("missing closing parenthesis")
            return value
        name = identifier()
        if take("WITH"):
            identifier()  # Exceptions never override this repository's deny policy.
        return not any(blocked in name.upper() for blocked in BLOCKING)

    def both():
        value = factor()
        while take("AND"):
            right = factor()
            value = value and right
        return value

    def either():
        value = both()
        while take("OR"):
            right = both()
            value = value or right
        return value

    try:
        return either() and index == len(tokens)
    except (ValueError, RecursionError):
        return False
