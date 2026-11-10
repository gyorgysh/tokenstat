#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Execute original complete Swift row/coalescer/fold/image/metadata owners.

Owned stdin/resources only; no host, real archive, preferences mutation or GUI.
"""
from pathlib import Path
import copy
import hashlib
import importlib.util
import itertools
import json
import plistlib
import random
import shutil
import subprocess
import sys
import tempfile
import unicodedata

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("linux-swiftui-contract.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def run(command, **kwargs):
    return subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True, timeout=300, **kwargs)


def cases():
    histories = []

    def agent(kind, **values):
        return {"kind": "agent", "event": {"kind": kind, **values}}

    def history(events, backend="codex", both=True):
        for running in [False, True] if both else [False]:
            histories.append({"events": copy.deepcopy(events), "backend": backend, "running": running})

    history([])
    history([agent("text", delta=""), agent("text"), agent("text", delta="  hello "), agent("thinking", delta="Plan"),
             agent("thinking", delta="…"), agent("text", delta="world"), {"kind": "user", "text": "Continue"}])
    for stable, call in itertools.product([False, True], [None, "", "tool", "café", "👩🏽‍💻"]):
        events = [{"kind": "user", "text": "Synthetic"}]
        for i, verb in enumerate(["Read", "Bash", "Edit", "NotebookEdit", "Read"]):
            events += [agent("toolStart", verb=verb, target=["a.rs", "b.rs", "a.rs"][i % 3], **({} if call is None else {"callId": call}))]
        events += [agent("edit", callId=call, path="a.rs", patch="--- a/file\n+++ b/file\n-old\n+new"),
                   agent("toolEnd", callId=call, detail="+one\n-two", ok=False), agent("toolEnd", callId=call, detail="Repeated"),
                   {"kind": "user", "text": "Steer", "steer": True}, agent("toolStart", verb="Edit", target="a.rs", callId=call),
                   agent("edit", callId=call, path="a.rs", added=4), agent("toolEnd", callId=call), agent("done", status="cancelled")]
        for i, event in enumerate(events):
            event["atMs"] = i * 100
            if stable:
                event["seq"] = i
        history(events)
    for status in [None, "error", "success", "cancelled", "future"]:
        history([agent("toolStart", callId="call", verb="Bash", target="sleep"), agent("done", status=status)])
    for empty, verb in itertools.product([None, ""], ["Edit", "NotebookEdit", "Diff", "Read", None]):
        history([agent("toolStart", verb=verb, target=empty), agent("edit", path=empty, patch="+new"), agent("toolEnd", verb=verb, target=empty, detail="-old\n+new")])
    history([agent("toolEnd", callId="orphan", verb="Read", target="a.rs", detail="Only an end"),
             agent("edit", callId="orphan", path="a.rs", added=1), agent("edit", callId="orphan", path="a.rs", removed=2),
             {"kind": "user", "text": "New turn"}, agent("edit", callId="orphan", path="a.rs", patch="+new"),
             agent("failed", text="Synthetic failure")])
    approval = {"id": "approval", "conversationId": "thread", "verb": "Run", "preview": "echo fixture", "createdAtMs": 1, "expiresAtMs": 3}
    history([agent("text", delta="Before"), {"kind": "approval", "approval": approval}, agent("text", delta="After"),
             {"kind": "approval", "approval": dict(approval, decision="allow")},
             {"kind": "question", "id": "q", "question": "Choose?", "options": ["A", "B"]},
             {"kind": "answer", "questionId": "q", "text": "A", "delivery": "queued"},
             {"kind": "answerWithdrawn", "questionId": "q"}, {"kind": "answer", "questionId": "other"},
             {"kind": "question", "id": "q", "question": "Again?", "default": "A", "multiple": True},
             {"kind": "answer", "questionId": "q", "delivery": "sent"}])
    for backend in [None, "", "muse"]:
        history([dict(agent("toolStart", callId="same", verb="Bash Input"), backend="muse", seq=0),
                 dict(agent("toolStart", callId="same", verb="Read"), backend="codex", seq=1),
                 dict(agent("toolEnd", callId="same", detail='{"command":"cargo test"}'), backend="codex", seq=2),
                 dict(agent("toolEnd", callId="same", detail="Finished"), backend="claude", seq=3),
                 {"kind": "handoff", "to": "claude", "brief": "Synthetic context"},
                 dict(agent("future"), backend="muse", seq=4)], backend=backend)
    for attributed in [False, True]:
        events = [agent("toolStart", callId="images", verb="Read", target="one.png"), agent("toolEnd", callId="images", detail="Loaded"),
                  agent("attachment", id="one", name="one.png", mediaType="image/png"),
                  agent("attachment", id="two", name="two.png", mediaType="image/png"),
                  agent("attachment", id="one", name="one.png", mediaType="image/png"),
                  {"kind": "user", "text": "More", "steer": True}, agent("attachment", id="three", name="", mediaType="image/png"),
                  {"kind": "user", "text": "New turn"}, agent("attachment", id="four", mediaType="image/png"),
                  agent("attachment", id="file", mediaType="text/plain"), agent("attachment", mediaType="image/png")]
        if attributed:
            for event in events:
                if event.get("event", {}).get("kind") == "attachment":
                    event["event"]["callId"] = "images"
        history(events)
    for costs in [[0.25, 0.5], [None, 0.5], [0, 0], [-1, 0.5]]:
        events = [{"kind": "user", "text": "Question"}, agent("thinking", delta="# Plan\nread it"),
                  agent("toolStart", verb="Read", callId="a", target=" a.rs\nsecond line"), agent("toolStart", verb="Search", callId="b", target="Needle"),
                  agent("toolStart", verb="WebFetch", callId="c", target="https://fixture.invalid"),
                  agent("edit", path="same.rs", added=2, removed=1), agent("text", delta="Reply"),
                  agent("edit", path="same.rs", added=3), agent("toolEnd", callId="a", detail="Loaded"), agent("thinking", delta="# Last thought")]
        events += [agent("usage", input=2**64-1, output=1, costUsd=cost) for cost in costs]
        history(events)
        history([agent("usage", input=2**64-1, output=1, costUsd=cost) for cost in costs])
    for count in [1, 2, 4, 7]:
        history([agent("toolStart", callId=str(i), verb=["Read", "Grep", "Bash", "Write"][i % 4], target=str(i)) for i in range(count)] +
                [agent("toolEnd", callId=str(i), detail="Done") for i in range(1, count)] + [agent("thinking", delta="A live thought")])
    rng = random.Random(0x71A5)
    for _ in range(48):
        events = []
        for i in range(36):
            call = rng.choice([None, "", "shared", "a", "é", "é"])
            verb = rng.choice([None, "", "Read", "Edit", "NotebookEdit", "Diff", "Grep", "WebSearch", "WebFetch", "Bash Input"])
            path = rng.choice(["a.rs", "é.rs", "é.rs", "", "nested/b.rs"])
            choice = rng.randrange(15)
            if choice == 0: event = {"kind": "user", "text": "Continue", "steer": rng.choice([True, False])}
            elif choice == 1: event = agent("text", delta=rng.choice([None, "", "  Reply ", "👩🏽‍💻", "é", "é"]))
            elif choice == 2: event = agent("thinking", delta="# Plan ")
            elif choice in [3, 4]: event = agent("toolStart", callId=call, verb=verb, target=path)
            elif choice in [5, 6]: event = agent("toolEnd", callId=call, verb=verb, target=path, detail=rng.choice([None, "", "+new\n-old", '{"command":"echo fixture"}']), ok=rng.choice([None, True, False]))
            elif choice == 7: event = agent("edit", callId=call, path=path, added=rng.randrange(3), removed=rng.randrange(3), patch="--- a/file\n+++ b/file\n-new\n+old")
            elif choice == 8: event = agent("done", status=rng.choice([None, "error", "success", "cancelled"]))
            elif choice == 9: event = agent("failed", text=rng.choice([None, "Synthetic failure"]))
            elif choice == 10: event = {"kind": "approval", "approval": dict(approval, id=rng.choice(["é", "é", "second"]), decision=rng.choice([None, "allow", "deny"]))}
            elif choice == 11: event = {"kind": "question", "id": "q", "question": "Choose?", "default": rng.choice([None, "A"])}
            elif choice == 12: event = {"kind": rng.choice(["answer", "answerWithdrawn"]), "questionId": "q", "text": "A"}
            elif choice == 13: event = agent("attachment", id=f"file-{i % 3}", mediaType="image/png", callId=call)
            else: event = {"kind": "handoff", "to": "muse", "brief": "Synthetic context"}
            event["atMs"] = i * 100
            event["backend"] = rng.choice([None, "codex", "muse", "claude"])
            if rng.randrange(3): event["seq"] = i
            events.append(event)
        history(events)
    auth_messages = ["Claude Code is not signed in. Sign in on this computer.", "Claude Code's sign-in on this computer has expired.",
                     "Cursor is not signed in on this machine.", "Error: Authentication required. Run 'agent login' or set CURSOR_API_KEY.",
                     "Authentication required. Run 'cursor-agent login' and CURSOR_API_KEY.", "Authentication required. Run 'cursor agent login' and CURSOR_API_KEY.",
                     "Authentication required. Run 'agent login'.", "Tool's GitHub login failed", "Muse is not signed in on this machine."]
    for backend, message in itertools.product([None, "claude", "codex", "cursor", "muse"], auth_messages):
        history([{"kind": "user", "text": "Synthetic retry"}, agent("attachment", id="user-file", mediaType="image/png"),
                 dict(agent("text", delta="Not logged in · Please run /login"), backend=backend), agent("usage", input=0, output=0),
                 agent("failed", text=message), agent("attachment", id="agent-file", mediaType="image/png")])
    urls = ["https://auth.meta.com/device", "HTTPS://auth.meta.com/device", "https://AUTH.meta.com/device", "https://auth.meta.com:443/device",
            "https://auth.meta.com:/device", "https://auth.meta.com:99999/device", "https://auth.meta.com:-1/device", "https://auth.meta.com:abc/device",
            "https://person:secret@auth.meta.com/device", "https://person@@auth.meta.com/device", "https://%61uth.meta.com/device", "https://auth%2Emeta.com/device",
            "https://auth.meta.com.evil.invalid/device", "https://evil.invalid/auth.meta.com", "http://auth.meta.com/device", "https:auth.meta.com/device",
            "https://auth.meta.com./device", "https://auth.meta.com?query", "https://auth.meta.com#fragment", "https://auth.meta.com/a path",
            "https://auth.meta.com:9223372036854775808/device", "https://auth.meta.com/%ZZ", "https://auth.meta.com\\evil.invalid/device"]
    for url, heading in itertools.product(urls, ["confirm this code matches:", "Confirm this code matches:"]):
        message = f"Open this page to sign in:\n{url}\n{heading}\nFAKE-CODE\nPress Enter to open it in your browser:"
        history([{"kind": "user", "text": "Synthetic"}, dict(agent("text", delta=message), backend="muse")])
    snippets = [{"verb": verb, "text": text} for verb, text in itertools.product(["Read", "Edit", "NotebookEdit", "Diff", "Bash"],
                ["", "+new", "-old", "+++ b/file", "--- a/file", "+́combining", "---́ path", "a\r\nb\nc\r\n", "\n", "\r\n", "a" * 599, "a" * 600, "a" * 601,
                 "é👩🏽‍💻" * 500, "x" + "́" * 5000, "line\n" * 59, "line\n" * 60, "line\n" * 61])]
    questions = []
    block = '```tokenstat-question\n{"question":"Choose?","options":["A","B"]}\n```'
    texts = ["plain unchanged\n", block, "Before\n" + block + "\nAfter", block.replace("\n", "\r\n"),
             '``` tokenstat-question\n{"question":"Choose?"}\n```', '```tokenstat-question\n{"question":"unfinished',
             '```tokenstat-question\n{"question":"  "}\n```', '```tokenstat-question\n["wrong"]\n```',
             '```tokenstat-question\n{"question":7}\n```', '```tokenstat-question\ninvalid\n```',
             "\n\n\nBefore\n" + block + "\n\n\nAfter", '```́tokenstat-question\n{"question":"No fence"}\n```']
    for length in [65534, 65535, 65536, 65537, 70000]:
        body = '{"question":"Choose?","padding":"' + 'é' * ((length - 34) // 2) + '"}'
        texts += ['```tokenstat-question\n' + body + '\n```', '```tokenstat-question\n' + body]
    for text, streaming in itertools.product(texts, [False, True]): questions.append({"text": text, "streaming": streaming})
    muse = []
    details = [None, "", '{"command":"cargo test","path":"a.rs","query":"needle","url":"https://fixture.invalid"}',
               '$ cargo test\noutput', 'Finished command\n$ cargo test\noutput', 'Nothing\nother\n$ never scan output',
               'Read text file `a.rs`.', '<read-skill-result name="a&amp;b&quot;&lt;&gt;&apos;" count="2">',
               '<read-skill-result\tname="skill">', '<read-skill-result name="">', '<read-skill-result name="skill"',
               'wrote 12 bytes to a.rs', 'wrote x bytes to a.rs', '12 todos (revision 7)', '12 todos (revision 7) extra',
               '$ cargo test\r\noutput', 'Finished\r\n$ cargo test\r\noutput', '{"command":""}', '{"path":""}']
    for backend, verb, target, detail in itertools.product([None, "muse", "codex"], ["Bash Input", "bash_input", "Read Skill", "read_skill", "Write Todos", "Bash", "Shell", "Read", "Write", "WebSearch", "WebFetch", "TodoWrite", "Unknown"], ["", " authoritative "], details):
        muse.append({"backend": backend, "verb": verb, "target": target, "detail": detail})
    for length in [131071, 131072, 131073]:
        muse.append({"backend": "muse", "verb": "Bash Input", "target": "", "detail": '$ echo ' + 'é' * (length // 2)})
    previews = ["", "## Plan\nread it", "\n\n   ### **Plan** ", "##\nnext", "# Plan\r\nSecond", "x" * 161, "👩🏽‍💻" * 161, "\t- `Details`  ", "\u200b# Plan\u200b", "#́ unchanged"]
    for scalar in [9, 10, 11, 12, 13, 28, 29, 30, 31, 32, 133, 160, 5760, *range(8192, 8204), 8232, 8233, 8239, 8287, 12288]:
        previews.append(chr(scalar) + "## Plan" + chr(scalar))
        questions.append({"text": chr(scalar) + '``` tokenstat-question' + chr(scalar) + '\n{"question":"Choose?"}\n```', "streaming": False})
        muse.append({"backend": "muse", "verb": "Read Skill", "target": "", "detail": '<read-skill-result' + chr(scalar) + 'name="synthetic">'})
    equality = []
    def normalized(value):
        if isinstance(value, dict): return {k: normalized(v) for k, v in value.items()}
        if isinstance(value, list): return [normalized(v) for v in value]
        return unicodedata.normalize("NFD", value) if isinstance(value, str) else value
    for original in histories[::max(1, len(histories) // 24)]:
        canonical = normalized(original)
        equality += [[original, canonical], [original, dict(canonical, events=canonical["events"] + [{"kind": "user", "text": "different"}])]]
    auth = [{"backend": backend, "text": message} for backend, message in itertools.product(["claude", "claude_code", "cursor", "cursor_agent", "muse", "codex", "unknown"], auth_messages + [" " + m for m in auth_messages] + [m.upper() for m in auth_messages])]
    return {"histories": histories, "snippets": snippets, "questions": questions, "muse": muse, "auth": auth,
            "clocks": list(itertools.product([0, 1, -1, 2**63-1, -(2**63)], [None, -1, 0, 1, 999, 1000, 1050, 9950, 10000, 10500, 2**63-1, -(2**63)])),
            "ordinals": [-13, -1, 0, 1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 111, 112, 113], "previews": previews, "equality": equality}


def normalize(value):
    if isinstance(value, dict): return {k: normalize(v) for k, v in value.items() if v is not None}
    if isinstance(value, list): return [normalize(v) for v in value]
    return value


def compare(a, b, path="transcript"):
    if isinstance(a, dict):
        assert isinstance(b, dict) and a.keys() == b.keys(), f"{path}: different keys {a.keys()} != {b.keys()}"
        for k in a: compare(a[k], b[k], f"{path}.{k}")
    elif isinstance(a, list):
        assert isinstance(b, list) and len(a) == len(b), f"{path}: different rows {len(a)} != {len(b)}"
        for i, (x, y) in enumerate(zip(a, b)): compare(x, y, f"{path}[{i}]")
    else:
        assert isinstance(a, bool) == isinstance(b, bool) and a == b, f"{path}: Swift {repr(a)[:160]} != Rust {repr(b)[:160]}"


def main():
    if sys.platform != "darwin": raise SystemExit("Run the unchanged Swift transcript reference on macOS.")
    output = ROOT / "target/linux-transcript-reference"
    output.mkdir(parents=True, exist_ok=True)
    (output / "manifest.json").unlink(missing_ok=True)
    harness = ROOT / "apps/linux/reference/TranscriptReference.swift"
    records = [c.declaration("Bridge/Models.swift", marker) for marker in ["struct ChatAttachment:", "struct ChatApproval:", "extension ChatApproval {"]]
    source = harness.read_text().replace("/* SOURCE_RECORDS */", "\n".join(records))
    directory = c.SOURCES / "Features/Workspaces/Chat"
    originals = [directory / name for name in ["ChatDisplayItem.swift", "ChatCoalescer.swift", "ChatQuestion.swift", "MuseToolPresentation.swift", "ChatTranscriptFold.swift", "ChatImageGrouping.swift", "ChatAuthenticationFailure.swift"]]
    originals += [c.SOURCES / "Bridge/ChatEvents.swift", c.SOURCES / "Design/L10n.swift"]
    data = cases()
    (output / "input.json").write_text(json.dumps(data, ensure_ascii=False) + "\n")
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--no-default-features", "--example", "transcript-contract"])
    with tempfile.TemporaryDirectory(prefix="isolated-", dir=output) as temporary:
        work = Path(temporary)
        rust = work / "transcript-contract"
        shutil.copy2(ROOT / "apps/linux/target/debug/examples/transcript-contract", rust)
        swift_source = work / "Reference.swift"
        swift_source.write_text(source)
        app = work / "Reference.app"
        resources = app / "Contents/Resources"
        (app / "Contents/MacOS").mkdir(parents=True)
        resources.mkdir()
        shutil.copytree(ROOT / "apps/localization/en", resources / "localization/en")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.example.tokenstat.transcript-reference", "CFBundleExecutable": "reference", "CFBundlePackageType": "APPL"}))
        swift = app / "Contents/MacOS/reference"
        run(["xcrun", "swiftc", "-parse-as-library", *originals, swift_source, "-o", swift])
        payload = json.dumps(data, ensure_ascii=False)
        actual = normalize(json.loads(run([rust], input=payload, capture_output=True, text=True).stdout))
        expected = normalize(json.loads(run([swift], input=payload, capture_output=True, text=True).stdout))
        for name, value in [("rust.json", actual), ("swift.json", expected)]:
            (output / name).write_text(json.dumps(value, ensure_ascii=False) + "\n")
        compare(expected, actual)
    inputs = [Path(__file__).resolve(), Path(__file__).with_name("linux-swiftui-contract.py"), harness, *originals, c.SOURCES / "Bridge/Models.swift",
              ROOT / "apps/localization/en/common.json", ROOT / "apps/localization/en/apple.json", ROOT / "apps/linux/src/localization.rs",
              ROOT / "apps/linux/src/chat.rs", ROOT / "apps/linux/src/chat/wire.rs", ROOT / "apps/linux/src/chat/transcript.rs", ROOT / "apps/linux/src/commands.rs",
              *sorted((ROOT / "apps/linux/src/chat/transcript").glob("*.rs")), ROOT / "apps/linux/src/drafts.rs", ROOT / "apps/linux/src/work/text.rs",
              ROOT / "apps/linux/examples/transcript-contract.rs", ROOT / "apps/linux/Cargo.toml", ROOT / "apps/linux/Cargo.lock"]
    manifest = {"purpose": "complete raw row coalescer, four detail folds and image ownership, helpers and equality; no mounted reader/render or GUI signoff",
        "cases": {k: len(v) for k, v in data.items()}, "foldStates": len(data["histories"]) * 12,
        "substitutions": ["manual full-field row serialization is a harness adapter", "nil object fields normalized as omitted", "English-only original L10n resources in owned temporary bundle"],
        "inputs": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(inputs))},
        "harnessSha256": hashlib.sha256(source.encode()).hexdigest(),
        "outputs": {name: hashlib.sha256((output / name).read_bytes()).hexdigest() for name in ["input.json", "rust.json", "swift.json"]},
        "swift": run(["swiftc", "--version"], capture_output=True, text=True).stdout.strip(), "rust": run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {len(data['histories'])} complete raw/image histories, {manifest['foldStates']} original detail/open states; helpers {manifest['cases']}")


if __name__ == "__main__": main()
