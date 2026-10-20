# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Use the installed 1.8+ CLI as the authoritative, offline chart validator."""
import json
import subprocess


def chart(spec, *, executable="tokenstat"):
    """Return validated Markdown to include verbatim in an assistant reply.

    No project, account or archive is opened. ``executable`` can name a test
    build. Invalid data raises ValueError with the CLI's validation message.
    """
    source = json.dumps(spec, ensure_ascii=False, allow_nan=False)
    if len(source.encode("utf-8")) > 256 * 1024:
        raise ValueError("A chart may contain at most 256 KiB of JSON")
    try:
        result = subprocess.run([executable, "chart", "-"], input=source,
                                text=True, encoding="utf-8", capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ValueError("A tokenstat 1.8 or newer CLI is required for validation") from error
    if result.returncode:
        raise ValueError(result.stderr.strip() or "Chart validation failed")
    return result.stdout.strip()
