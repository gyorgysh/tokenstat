#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-tokenstat-source-available
"""Execute original async page and publication bodies with suspended CPU delivery.

Every record, resource and continuation is owned/synthetic. No real host or GUI.
"""
from pathlib import Path
import copy
import hashlib
import importlib.util
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location("transcript",Path(__file__).with_name("linux-swiftui-transcript.py"))
t=importlib.util.module_from_spec(spec);spec.loader.exec_module(t)
c=t.c


def run(command,**kwargs):
    return subprocess.run([str(a) for a in command],cwd=ROOT,check=True,timeout=kwargs.pop("timeout",300),**kwargs)


def async_bool_declaration(source,marker):
    # Default closure arguments contain braces before the function body.
    # Keep the entire unchanged signature, then scan from its actual body.
    start=source.index(marker)
    body=source.index(") async -> Bool {",start)+len(") async -> Bool ")
    return source[start:body]+c.declaration_text(source[body:],"{")


def cases():
    def event(seq):return {"kind":"agent","seq":seq,"event":{"kind":"text","delta":f"Text {seq}. "}}
    def page(seqs,**kw):return {"events":[event(s) for s in seqs],"nextOffset":50,"tailCursor":"tail:50","cursor":"older","hasEarlier":True,**kw}
    seed=page([50,51])
    def start(id,kind,value=None):return {"op":"start","id":id,"kind":kind,"value":value}
    def deliver(id):return {"op":"deliver","id":id}
    traces=[]
    def trace(*actions):traces.append({"seed":copy.deepcopy(seed),"actions":actions})
    older=page([10,20],cursor=None,hasEarlier=False)
    tail={"events":[event(52)],"nextOffset":80,"tailCursor":"tail:80"}
    for first,second in [("older","tail"),("tail","older")]:
        trace(start("older","earlier",older),start("tail","tail",tail),deliver(first),deliver(second),deliver(second))
    for kind,value in [("tail",tail),("earlier",older),("open",page([90],hasEarlier=False))]:
        trace(start("a",kind,value),{"op":"metadata","backend":"muse","running":True,"revision":9},deliver("a"),deliver("a"))
        trace(start("a",kind,value),{"op":"select","id":"second"},deliver("a"))
        trace(start("a",kind,value),{"op":"cancel","id":"a"})
    trace(start("a","metadata"),start("b","tail",tail),deliver("b"),deliver("a"),deliver("a"))
    trace(start("a","metadata"),{"op":"metadata","backend":"muse","running":True},start("b","metadata"),deliver("a"),deliver("b"))
    trace(start("a","metadata"),{"op":"metadata","revision":20},deliver("a"))
    trace(start("a","open",page([90])),start("b","earlier",older),deliver("b"),deliver("a"))
    trace(start("a","tail",tail),start("b","earlier",page([100],reset=True,hasEarlier=False,cursor=None)),deliver("a"),deliver("b"))
    trace(start("a","tail",tail),start("b","tail",{"events":[event(53)],"nextOffset":90}),deliver("a"),deliver("b"))
    trace(start("a","tail",tail),{"op":"metadata","backend":"muse"},{"op":"metadata","backend":"fixture"},deliver("a"))
    trace({"op":"metadata","backend":"café"},start("a","metadata"),{"op":"metadata","backend":"café"},deliver("a"))
    trace(start("a","open",page([90])),start("b","earlier",page([])),deliver("b"),deliver("a"))
    trace(start("a","tail",tail),start("b","tail",{"events":[],"nextOffset":50,"tailCursor":"rotated"}),deliver("a"))
    trace(start("a","open",page([],hasEarlier=False,cursor=None)),deliver("a"),start("b","open",page([],hasEarlier=False,cursor=None)),deliver("b"))
    for first,second in [("a","b"),("b","a")]:
        trace(start("a","open",page([90])),start("b","earlier",page([100],reset=True,hasEarlier=False,cursor=None)),deliver(first),deliver(second))
    trace({"op":"metadata","backend":"muse"},start("a","metadata"),start("b","open",page([90])),deliver("a"),deliver("b"))
    trace(start("a","metadata"),start("b","open",page([90])),deliver("b"),deliver("a"),deliver("a"))
    return {"traces":traces}


def main():
    if sys.platform!="darwin":raise SystemExit("Run original suspended-publication comparison on macOS.")
    assert sys.argv[1:] in [[],["--compare-gpui"]],"Usage: linux-swiftui-publication.py [--compare-gpui]"
    compare_gpui="--compare-gpui" in sys.argv
    output=ROOT/"target/linux-publication-reference";output.mkdir(parents=True,exist_ok=True)
    (output/"manifest.json").unlink(missing_ok=True)
    model="Features/Workspaces/Chat/ChatModel.swift"
    records=[c.declaration(path,marker) for path,marker in [
        ("Bridge/Models.swift","struct ChatSharingMarker:"),("Bridge/Models.swift","struct ChatConversation:"),
        ("Bridge/GitPullModels.swift","struct BranchPull:"),("Bridge/Models.swift","struct ChatAttachment:"),
        ("Bridge/Models.swift","struct ChatApproval:"),("Bridge/Models.swift","extension ChatApproval {"),
        ("Bridge/Models.swift","struct ChatEventPage:"),("Bridge/Models.swift","struct ChatEventChunk:"),
        ("Bridge/Models.swift","private struct FailableChatEvent:"),("Features/Workspaces/Chat/ChatCostMeter.swift","struct ChatUsageTotals:")]]
    methods=[c.declaration(model,marker) for marker in ["private func beginWindowReplacement()","private func finishWindowReplacement(","private func forgetWindow()",
        "private func readOpeningEvents(","private func loadEarlier(id:","private func isUnknownMethod(","private func loadEvents(","private func selectionMatches("]]
    paging_path=ROOT/"apps/linux/reference/ReaderPagingReference.swift"
    paging=paging_path.read_text()
    for token,marker in [("PAGE","static func chatEventPage("),("CHUNK","static func chatEvents(")]:
        paging=paging.replace(f"/* SOURCE_{token}_BRIDGE */",c.declaration("Bridge/Bridge.swift",marker))
    inert=async_bool_declaration(paging,"    func publishEvents(")
    original=async_bool_declaration((c.SOURCES/model).read_text(),"private func publishEvents(")
    assert "let initialRevision = eventsRevision" in original and "commitDisplay(rows)" in original and "recordsChanged: Bool = true" in original
    paging=paging.replace(inert,original)
    paging=paging.replace("var events: [ChatTimelineEvent] = []",c.declaration(model,"private(set) var events:"))
    additions='''var eventsRevision: UInt64=0
    var displayRevision: UInt64=0
    var displayCache: [ChatDisplayItem]=[]
    var displayKey: DisplayKey?
    var foldKey: Int?
    var hasRunningToolCacheKey: Int?
    let transcriptProjector=Gate()
    '''+c.declaration(model,"private struct DisplayKey:").replace("private struct","struct",1)+"\n"+c.declaration(model,"private func commitDisplay(")
    paging=paging.replace("/* SOURCE_WINDOW_METHODS */","\n".join(methods)+"\n"+additions)
    serializer_path=ROOT/"apps/linux/reference/TranscriptReference.swift"
    serializer=serializer_path.read_text().split("@main enum TranscriptReference")[0].replace("/* SOURCE_RECORDS */","")
    harness=ROOT/"apps/linux/reference/PublicationReference.swift"
    source="import Foundation\nstruct WorkReference {var workspaceID:String;var itemID:String?}\n"+"\n".join(records)+serializer+paging+harness.read_text()
    directory=c.SOURCES/"Features/Workspaces/Chat"
    originals=[directory/name for name in ["ChatDisplayItem.swift","ChatCoalescer.swift","ChatQuestion.swift","MuseToolPresentation.swift","ChatTranscriptFold.swift","ChatImageGrouping.swift","ChatTranscriptProjector.swift","ChatAuthenticationFailure.swift","ChatPaging.swift"]]
    originals += [c.SOURCES/"Bridge/ChatEvents.swift",c.SOURCES/"Bridge/ChatRoutingModels.swift",c.SOURCES/"Design/L10n.swift"]
    data=cases();payload=json.dumps(data)
    run(["cargo","build","--manifest-path","apps/linux/Cargo.toml","--no-default-features","--locked","--example","publication-contract"])
    with tempfile.TemporaryDirectory(prefix="isolated-",dir=output) as temporary:
        work=Path(temporary);rust=work/"publication-contract";shutil.copy2(ROOT/"apps/linux/target/debug/examples/publication-contract",rust)
        swift_source=work/"Reference.swift";swift_source.write_text(source)
        app=work/"Reference.app";resources=app/"Contents/Resources";(app/"Contents/MacOS").mkdir(parents=True);resources.mkdir()
        shutil.copytree(ROOT/"apps/localization/en",resources/"localization/en")
        (app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.example.tokenstat.publication-reference","CFBundleExecutable":"reference","CFBundlePackageType":"APPL"}))
        swift=app/"Contents/MacOS/reference"
        run(["xcrun","swiftc","-parse-as-library",*originals,swift_source,"-o",swift])
        actual=t.normalize(json.loads(run([rust],input=payload,capture_output=True,text=True).stdout))
        expected=t.normalize(json.loads(run([swift],input=payload,capture_output=True,text=True).stdout))
        for name,value in [("input.json",data),("rust.json",actual),("swift.json",expected)]:
            (output/name).write_text(json.dumps(value,ensure_ascii=False,indent=2)+"\n")
        t.compare(expected,actual,"publication")
    if compare_gpui:
        run(["cargo","build","--manifest-path","apps/linux/Cargo.toml","--locked","--example","projector-executor"])
        result=json.loads(run([ROOT/"apps/linux/target/debug/examples/projector-executor"],capture_output=True,text=True,timeout=30).stdout)
        assert result=={"accepted":True,"foregroundResume":True,"registeredWake":True,"backgroundGuard":True,"rawRowsAtomic":True,"metadataTickets":True,"cancelled":True,"windowsOpened":0,"hostOrStoreOpened":False},result
        (output/"gpui-executor.json").write_text(json.dumps(result,indent=2)+"\n")
    inputs=[Path(__file__).resolve(),Path(__file__).with_name("linux-swiftui-transcript.py"),Path(__file__).with_name("linux-swiftui-contract.py"),paging_path,serializer_path,harness,*originals,c.SOURCES/model,c.SOURCES/"Bridge/Bridge.swift",c.SOURCES/"Bridge/Models.swift",c.SOURCES/"Bridge/GitPullModels.swift",directory/"ChatCostMeter.swift",
        ROOT/"apps/linux/examples/publication-contract.rs",ROOT/"apps/linux/examples/projector-executor.rs",ROOT/"apps/linux/src/chat/projector.rs",ROOT/"apps/linux/src/chat/paging.rs",ROOT/"apps/linux/src/chat/paging/publication.rs",ROOT/"apps/linux/src/chat/wire.rs",ROOT/"apps/linux/src/chat/transcript.rs",*sorted((ROOT/"apps/linux/src/chat/transcript").glob("*.rs")),ROOT/"apps/linux/src/commands.rs",ROOT/"apps/linux/src/drafts.rs",ROOT/"apps/linux/src/work/text.rs",ROOT/"apps/linux/src/localization.rs",ROOT/"apps/localization/en/common.json",ROOT/"apps/localization/en/apple.json",ROOT/"apps/linux/Cargo.toml",ROOT/"apps/linux/Cargo.lock"]
    manifest={"traces":len(data["traces"]),"checkpoints":sum(len(t["actions"]) for t in data["traces"]),
        "substitutions":["selection setup and minimal scope/secondary owners follow ReaderPagingReference","explicit metadata operations stand in for selected observation/task creation","original actor computes first; a gate suspends delivery to the original publishEvents continuation","Rust CPU uses real temporary threads; GPUI background scheduling requires separate acceptance","manual full-field display serialization and nil omission normalization","private English original resources"],
        "inputs":{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(set(inputs))},"harnessSha256":hashlib.sha256(source.encode()).hexdigest(),
        "gpuiExecutorChecked":compare_gpui,
        "outputs":{n:hashlib.sha256((output/n).read_bytes()).hexdigest() for n in ["input.json","rust.json","swift.json"]+(["gpui-executor.json"] if compare_gpui else [])},"swift":run(["swiftc","--version"],capture_output=True,text=True).stdout.strip(),"rust":run(["rustc","--version"],capture_output=True,text=True).stdout.strip()}
    (output/"manifest.json").write_text(json.dumps(manifest,indent=2)+"\n")
    print(f"PASS: {manifest['traces']} original suspended-publication traces / {manifest['checkpoints']} checkpoints")


if __name__=="__main__":main()
