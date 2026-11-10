#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Compare full reader wire decoding and warm rows with unchanged Swift owners.

Synthetic stdin only. No host, archive, account, preferences or GUI is opened.
"""
from pathlib import Path
import copy
import hashlib
import importlib.util
import itertools
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("contract", Path(__file__).with_name("linux-swiftui-contract.py"))
c = importlib.util.module_from_spec(spec)
spec.loader.exec_module(c)


def run(command, **kwargs):
    return subprocess.run([str(arg) for arg in command], cwd=ROOT, check=True, timeout=300, **kwargs)


def cases():
    wire = []

    def add(kind, value):
        wire.append({"type": kind, "value": copy.deepcopy(value)})

    conversation = {"id": "thread", "workspaceId": "folder", "title": "A conversation", "backend": "fixture"}
    agent = {"kind": "text", "delta": "Readable text"}
    event = {"kind": "agent", "seq": 42, "event": agent}
    approval = {"id": "approval", "conversationId": "thread", "verb": "Run", "preview": "echo fixture", "createdAtMs": 1, "expiresAtMs": 2}
    routing = {"policy": {}, "waiting": False, "needsDeliveryCheck": False, "tried": []}
    full = dict(conversation, personaId="persona", model="fixture-model", effort="high", fastMode=True,
                systemPrompt="Synthetic setup", mode="execute", autonomy="standard", resumeToken="synthetic-resume",
                allowedTools=["Read"], allowedShellPrefixes=["echo"], budgetSeconds=300, createdAtMs=1,
                updatedAtMs=2, lastMessageAtMs=3, lastMessageAuthor="agent", sendRevision=5, runRevision=4,
                runStartedAtMs=3, running=True, pendingSteer="Synthetic note", nativeSteer=True,
                nativeSteerAttachments=True, branch="main", teamShare={"id": "share"}, routing=routing,
                pull={"number": 12, "title": "A pull", "url": "https://fixture.invalid/pull/12", "state": "open", "draft": False, "baseRef": "main"})
    for value in [conversation, full]:
        add("conversation", value)
        for field in value:
            absent = copy.deepcopy(value)
            del absent[field]
            add("conversation", absent)
            for wrong in [None, False, True, 0, 1.0, -1, "wrong", [], {}, ["one", 7]]:
                add("conversation", dict(value, **{field: wrong}))
    for field in ["budgetSeconds", "createdAtMs", "updatedAtMs", "lastMessageAtMs", "sendRevision", "runRevision", "runStartedAtMs"]:
        for value in [-(2**63), 2**63 - 1, 2**63, 2**64 - 1, 2**64, -0.0, 0.5, 1.0, 1.5, 9007199254740993]:
            add("conversation", dict(conversation, **{field: value}))
    for field in routing:
        for wrong in [None, False, 0, "wrong", [], {}]:
            add("conversation", dict(conversation, routing=dict(routing, **{field: wrong})))
    for policy in [{}, {"routes": [{"backend": "fixture", "model": "m", "effort": "high"}], "enabled": True}, {"routes": [None]}, {"enabled": "yes"}, {"notify": False}]:
        add("conversation", dict(conversation, routing=dict(routing, policy=policy)))
    for field in full["pull"]:
        for value in [None, True, False, 1, 1.0, 0.5, -1, 2**32-1, 2**32, "wrong", [], {}]:
            add("conversation", dict(conversation, pull=dict(full["pull"], **{field: value})))
    add("conversation", dict(conversation, routing=dict(routing,
        limit={"provider": "fixture", "kind": "usage", "reason": "Synthetic", "observedAtMs": 5, "resetsAtMs": 7},
        preferred={"backend": "fixture"}, nextReset={"destination": {"backend": "fixture"}, "atMs": 12},
        activity=[{"atMs": 5, "kind": "switched", "reason": "Synthetic", "source": {"backend": "fixture"}, "target": {"backend": "second"}}])))
    full_agent = dict(agent, verb="Read", target="fixture.rs", path="fixture.rs", added=2, removed=1, patch="+fixture",
                      status="ok", text="Synthetic", input=12, output=7, costUsd=0.001, callId="call", ok=True,
                      detail="Synthetic output", cacheRead=3, cacheWrite=2, exitCode=0, id="file", name="fixture.png", mediaType="image/png", size=128)
    for kind, base in [("agent", full_agent), ("event", dict(event, text="Question", steer=True, atMs=7, backend="fixture", approval=approval,
                    to="second", brief="Synthetic handoff", id="question", question="Which file?", options=["A", "B"], multiple=True,
                    default="A", blocking=False, questionId="question", delivery="reply"))]:
        add(kind, base)
        for field in base:
            absent = copy.deepcopy(base)
            del absent[field]
            add(kind, absent)
            for value in [None, False, True, 1.0, -1, 0.5, "wrong", [], {}, ["A", 3]]:
                add(kind, dict(base, **{field: value}))
    for field in ["input", "output", "cacheRead", "cacheWrite", "size", "added", "removed", "exitCode"]:
        for value in [0, 1.75, -0.0, -0.5, -1, 2**32 - 1, 2**32, -(2**31), 2**31 - 1, 2**31, 2**63, 2**64 - 1, 2**64, 9007199254740993]:
            add("agent", dict(agent, **{field: value}))
    for primary, legacy in [("costUsd", "cost_usd"), ("callId", "call_id"), ("exitCode", "exit_code"), ("cacheRead", "cache_read"), ("cacheWrite", "cache_write")]:
        for a, b in itertools.product([None, 1, "wrong", {}, -1, 1.5], repeat=2):
            add("agent", dict(agent, **{primary: a, legacy: b}))
    for a, b in itertools.product([None, 1, "wrong", {}, -1, 1.5], repeat=2):
        add("event", {"kind": "future-kind", "atMs": a, "at_ms": b})
    for read_only in [None, False, True, "wrong"]:
        for private_id in [None, "thread", 123, {}, False]:
            add("event", {"kind": "approval", "approval": dict(approval, readOnly=read_only, conversationId=private_id)})
    malformed = [{"kind": "user", "text": "Kept", "seq": 0}, None, {"kind": "agent", "event": {"kind": "tool", "input": {"path": "fixture"}}},
                 {"kind": "agent", "event": {"kind": "text", "delta": 7}}, {"kind": "future-kind"}, {"kind": 7}, False]
    for kind, full_page in [("page", {"events": malformed, "nextOffset": 12, "tailCursor": "opaque:tail", "cursor": "opaque:earlier", "hasEarlier": True,
                                      "historyTrimmed": True, "reset": True, "usage": {"input": 2, "output": 3, "cacheRead": 4, "cacheWrite": 5, "cost": 0.1}}),
                            ("chunk", {"events": malformed, "nextOffset": 12, "tailCursor": "opaque:tail", "reset": False, "hasMore": True})]:
        add(kind, full_page)
        add(kind, {})
        for field in full_page:
            for value in [None, False, True, 1.0, -1, "wrong", [], {}, [None]]:
                add(kind, dict(full_page, **{field: value}))
        for bad in [None, False, [], 1, "wrong"]:
            add(kind, bad)

    caches = []

    def store(key, rows=None, speculative=False):
        return {"op": "store", "key": key, "rows": rows if rows is not None else [{"id": key, "cost": 10}], "speculative": speculative}

    def trace(keys, actions):
        caches.append({"keys": keys, "actions": actions})

    for speculative in [False, True]:
        keys = [f"scope|host|folder|{i}" for i in range(14)]
        trace(keys, [store(k, speculative=speculative and i % 2 == 0) for i, k in enumerate(keys[:10])] +
              [{"op": "peek", "key": keys[0]}, {"op": "messages", "key": keys[1]}, store(keys[10]), store(keys[11]),
               store(keys[12], speculative=True), {"op": "messages", "key": keys[12]}, store(keys[13]),
               {"op": "retain", "folder": "scope|host|folder|", "keys": [keys[5], keys[12]]}, {"op": "clear"}])
    keys = [f"scope|host|folder-{i // 8}|{i}" for i in range(67)]
    for speculative in [False, True]:
        trace(keys, [store(k, speculative=speculative and i % 3 == 0) for i, k in enumerate(keys)] +
              [{"op": "messages", "key": keys[10]}, {"op": "remove", "key": keys[11]}, store(keys[0])])
    rows = [{"id": i, "cost": 1} for i in range(170)]
    for costs in [[], [524288], [524289], [-1, -3, 0], [1, 524288], [524289, 1], [1, 524287, 1], [1, 2**63-1], [524288, -1]]:
        trace(["a|one"], [store("a|one"), store("a|one", [{"id": i, "cost": cost} for i, cost in enumerate(costs)]), {"op": "messages", "key": "a|one"}])
    trace(["a|one"], [store("a|one", rows), store("a|one", [])])
    keys = ["café|one", "café|one", "café|two", "café|three", "x́|one", "x|one", "no-separator", "other"]
    trace(keys, [store(k) for k in keys] + [{"op": "messages", "key": "café|one"}, {"op": "retain", "folder": "x", "keys": []},
              {"op": "retain", "folder": "café|", "keys": ["café|one"]}, {"op": "remove", "key": "café|one"}, {"op": "clear"}])
    revisions = list(itertools.product([None, 0, 1, 2, 3, 2**64-2, 2**64-1], repeat=3))
    return {"wire": wire, "caches": caches, "revisions": revisions, "windows": window_cases()}


def window_cases():
    usage = {"input": 100, "output": 20, "cacheRead": 10, "cacheWrite": 5, "cost": 0.01}

    def event(seq, text="Synthetic"):
        return {"kind": "user", "seq": seq, "text": text}

    def page(rows=None, **values):
        return dict({"events": rows if rows is not None else [event(10), event(11)], "nextOffset": 50, "tailCursor": "opaque:tail",
                     "cursor": "opaque:before", "hasEarlier": True, "usage": usage}, **values)

    def read(op, value=None, responses=None, quiet=False):
        return {"op": op, "responses": responses if responses is not None else [{"value": value}], "quiet": quiet}

    def trace(*actions):
        return {"actions": [{"op": "select", "id": "first"}, *actions]}

    traces = [trace(read("open", page()), read("earlier", page([event(3), event(None), event(9), event(10)], cursor="opaque:begin", hasEarlier=True)),
                    read("tail", {"events": [event(12)], "nextOffset": 75, "tailCursor": "opaque:second", "hasMore": True}),
                    read("earlier", page([], cursor=None, hasEarlier=False)),
                    read("tail", {"events": [], "nextOffset": 75, "tailCursor": "opaque:rotated", "hasMore": True})),
              trace(read("open", page([], cursor=None, hasEarlier=False)), read("earlier", responses=[]),
                    read("tail", {"events": [event(0)], "nextOffset": 10, "tailCursor": "opaque:new"})),
              {"actions": [{"op": "select", "id": "fresh", "fresh": True}, read("tail", {"events": [], "nextOffset": 0})]},
              trace(read("tail", page())),
              trace(read("open", page([event(None), event(11)])), read("earlier", page([event(None), event(11), event(2**64-1)], cursor=None, hasEarlier=False))),
              trace(read("open", page()), {"op": "revision", "value": 12}, read("earlier", page([event(30)], reset=True, historyTrimmed=True, hasEarlier=False, cursor=None)),
                    read("tail", {"events": [], "nextOffset": 50})),
              trace(read("open", page(cursor=None)), read("earlier", responses=[])),
              trace(read("open", page()), read("tail", responses=[{"value": {"reset": True}}, {"value": page([event(100)], historyTrimmed=True)}])),
              trace(read("open", page()), read("tail", responses=[{"value": {"reset": True}}, {"error": "failed page"}, {"error": "failed fallback"}])),
              trace(read("open", responses=[{"value": page(), "revision": 8}]), read("tail", {"events": [], "nextOffset": 50})),
              trace(read("open", responses=[{"value": page(), "select": "second"}]), read("open", page([event(3)]))),
              trace(read("open", page()), read("tail", responses=[{"value": {"events": [event(20)], "nextOffset": 80}, "select": "second"}]), read("open", page())),
              trace(read("open", page()), read("earlier", responses=[{"value": page([event(3)]), "select": "second"}]), read("open", page()))]
    for quiet, unknown, fallback in itertools.product([False, True], [False, True], ["success", "error", "reset"]):
        answer = {"value": {"events": [event(1)], "nextOffset": 10}} if fallback == "success" else (
            {"error": "fallback failed"} if fallback == "error" else {"value": {"reset": True}})
        traces.append(trace(read("open", responses=[{"error": "page failed", "unknown": unknown}, answer], quiet=quiet),
                            read("open", {"events": [], "nextOffset": 0} if unknown else page(), quiet=quiet)))
    for quiet in [False, True]:
        traces.append(trace(read("open", page()),
                            read("open", responses=[{"ownerChanged": True, "error": "owner changed"},
                                                    {"value": {"events": [event(100)], "nextOffset": 101}}], quiet=quiet)))
    for quiet, unknown in itertools.product([False, True], repeat=2):
        traces.append(trace(read("open", page()), read("earlier", responses=[{"error": "older failed", "unknown": unknown}], quiet=quiet),
                            read("earlier", responses=[] if unknown else [{"value": page([], cursor=None, hasEarlier=False)}], quiet=quiet),
                            read("tail", responses=[{"error": "tail failed"}], quiet=quiet), read("tail", {"events": [], "nextOffset": 50})))
    for reset, trimmed in itertools.product([False, True], repeat=2):
        traces.append(trace(read("open", page(historyTrimmed=trimmed)), read("earlier", page([], reset=reset, historyTrimmed=not trimmed, hasEarlier=False, cursor=None))))
    return traces


def normalize(value):
    # Swift encodeIfPresent omits nil; older Rust records use explicit null.
    if isinstance(value, dict):
        return {k: normalize(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [normalize(v) for v in value]
    return value


def compare(expected, actual, path="reader"):
    # Wire counters/revisions and costs are exact. Font-geometry tolerances in
    # the broader contract comparator must not mask a decoder difference here.
    if isinstance(expected, dict):
        assert isinstance(actual, dict) and expected.keys() == actual.keys(), f"{path}: different keys"
        for key in expected:
            compare(expected[key], actual[key], f"{path}.{key}")
    elif isinstance(expected, list):
        assert isinstance(actual, list) and len(expected) == len(actual), f"{path}: different rows"
        for index, (left, right) in enumerate(zip(expected, actual)):
            compare(left, right, f"{path}[{index}]")
    else:
        assert isinstance(expected, bool) == isinstance(actual, bool) and expected == actual, f"{path}: Swift {expected!r} != Rust {actual!r}"


def main():
    if sys.platform != "darwin":
        raise SystemExit("Run the unchanged Swift wire/cache reference on macOS.")
    output = ROOT / "target/linux-reader-reference"
    output.mkdir(parents=True, exist_ok=True)
    (output / "manifest.json").unlink(missing_ok=True)
    harness = ROOT / "apps/linux/reference/ReaderReference.swift"
    records, extracted = [], []
    for path, marker in [
        ("Bridge/Models.swift", "struct ChatSharingMarker:"), ("Bridge/Models.swift", "struct ChatConversation:"),
        ("Bridge/GitPullModels.swift", "struct BranchPull:"), ("Bridge/Models.swift", "struct ChatApproval:"),
        ("Bridge/Models.swift", "extension ChatApproval {"), ("Bridge/Models.swift", "struct ChatEventPage:"),
        ("Bridge/Models.swift", "struct ChatEventChunk:"), ("Bridge/Models.swift", "private struct FailableChatEvent:"),
        ("Features/Workspaces/Chat/ChatCostMeter.swift", "struct ChatUsageTotals:")]:
        records.append(c.declaration(path, marker))
        extracted.append(c.SOURCES / path)
    for path in ["Bridge/ChatEvents.swift", "Bridge/ChatRoutingModels.swift", "Features/Workspaces/Chat/ChatRecentMessages.swift",
                 "Features/Workspaces/Chat/ChatSendContext.swift", "Features/Workspaces/Chat/ChatPaging.swift"]:
        records.append((c.SOURCES / path).read_text())
        extracted.append(c.SOURCES / path)
    source = harness.read_text().replace("/* SOURCE_RECORDS */", "\n".join(records))
    paging_harness = ROOT / "apps/linux/reference/ReaderPagingReference.swift"
    paging = paging_harness.read_text()
    model_path = "Features/Workspaces/Chat/ChatModel.swift"
    methods = [c.declaration(model_path, marker) for marker in ["private func beginWindowReplacement()", "private func finishWindowReplacement(",
               "private func forgetWindow()", "private func readOpeningEvents(", "private func loadEarlier(id:", "private func isUnknownMethod(",
               "private func loadEvents(", "private func selectionMatches("]]
    paging = paging.replace("/* SOURCE_WINDOW_METHODS */", "\n".join(methods))
    for token, marker in [("PAGE", "static func chatEventPage("), ("CHUNK", "static func chatEvents(")]:
        paging = paging.replace(f"/* SOURCE_{token}_BRIDGE */", c.declaration("Bridge/Bridge.swift", marker))
    source = source.replace("/* SOURCE_PAGING */", paging)
    extracted += [c.SOURCES / model_path, c.SOURCES / "Bridge/Bridge.swift"]
    data = cases()
    payload = json.dumps(data, ensure_ascii=False)
    run(["cargo", "build", "--manifest-path", "apps/linux/Cargo.toml", "--locked", "--no-default-features", "--example", "reader-contract"])
    with tempfile.TemporaryDirectory(prefix="isolated-", dir=output) as temporary:
        work = Path(temporary)
        rust = work / "reader-contract"
        shutil.copy2(ROOT / "apps/linux/target/debug/examples/reader-contract", rust)
        swift_source, swift = work / "Reference.swift", work / "reference"
        swift_source.write_text(source)
        run(["xcrun", "swiftc", "-parse-as-library", swift_source, "-o", swift])
        actual = normalize(json.loads(run([rust], input=payload, capture_output=True, text=True).stdout))
        expected = normalize(json.loads(run([swift], input=payload, capture_output=True, text=True).stdout))
        for name, value in [("input.json", data), ("rust.json", actual), ("swift.json", expected)]:
            (output / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
        compare(expected, actual)
    inputs = [Path(__file__).resolve(), Path(__file__).with_name("linux-swiftui-contract.py"), harness, paging_harness, *extracted,
              ROOT / "apps/linux/examples/reader-contract.rs", ROOT / "apps/linux/src/chat.rs",
              ROOT / "apps/linux/examples/contracts/reader_paging.rs",
              ROOT / "apps/linux/src/chat/projector.rs", ROOT / "apps/linux/src/chat/paging/publication.rs",
              ROOT / "apps/linux/src/chat/transcript.rs", *sorted((ROOT / "apps/linux/src/chat/transcript").glob("*.rs")),
              *[ROOT / "apps/linux/src/chat" / name for name in ["wire.rs", "recent_messages.rs", "send_context.rs", "paging.rs"]],
              ROOT / "apps/linux/Cargo.toml", ROOT / "apps/linux/Cargo.lock"]
    manifest = {"purpose": "complete wire decoding, paging constants, warm-row eviction and context revision source comparison; no mounted reader or GUI signoff",
                "wireCases": len(data["wire"]), "cacheTraces": len(data["caches"]), "cacheCheckpoints": sum(len(t["actions"]) for t in data["caches"]),
                "revisionCases": len(data["revisions"]), "windowTraces": len(data["windows"]), "windowCheckpoints": sum(len(t["actions"]) for t in data["windows"]),
                "substitutions": ["inert WorkReference supplies only saved initializer signature", "L10n returns keys", "nil object fields normalized as omitted", "cache rows and costs are synthetic dictionaries",
                    "selection fixture setup is not the full select/load owner", "immediate publication replaces off-thread projection; concurrent CPU publication is unverified", "opening wrapper directly calls original readOpeningEvents; opening actor tested separately elsewhere",
                    "outgoing, saved-copy keeping, attachment scheduling, notifications and markdown warmup are inert; currentReference is nil"],
                "inputs": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(inputs))},
                "harnessSha256": hashlib.sha256(source.encode()).hexdigest(),
                "outputs": {name: hashlib.sha256((output/name).read_bytes()).hexdigest() for name in ["input.json", "rust.json", "swift.json"]},
                "swift": run(["swiftc", "--version"], capture_output=True, text=True).stdout.strip(),
                "rust": run(["rustc", "--version"], capture_output=True, text=True).stdout.strip()}
    (output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"PASS: {manifest['wireCases']} full reader wire cases; {manifest['cacheTraces']} original warm-row traces / {manifest['cacheCheckpoints']} checkpoints; {manifest['revisionCases']} context revisions")
    print(f"PASS: {manifest['windowTraces']} original newest/earlier/tail window traces / {manifest['windowCheckpoints']} checkpoints")


if __name__ == "__main__":
    main()
