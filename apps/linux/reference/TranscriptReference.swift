// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation
/* SOURCE_RECORDS */
func json<T:Encodable>(_ value:T)->Any{try! JSONSerialization.jsonObject(with:JSONEncoder().encode(value),options:[.fragmentsAllowed])}
func optional<T>(_ value:T?)->Any{value as Any? ?? NSNull()}
func tool(_ s:ChatToolState)->[String:Any]{[
    "callId":s.callId,"verb":s.verb,"target":s.target,"running":s.running,"failed":s.failed,"detail":optional(s.detail),
    "startedAtMs":s.startedAtMs,"endedAtMs":optional(s.endedAtMs),"snippet":s.snippet]}
func edit(_ s:ChatEditState)->[String:Any]{[
    "path":s.path,"added":s.added,"removed":s.removed,"patch":s.patch,"revision":s.revision,"running":s.running,"failed":s.failed,
    "startedAtMs":s.startedAtMs,"endedAtMs":optional(s.endedAtMs)]}
func group(_ g:ChatStepGroup)->[String:Any]{[
    "style":String(describing:g.style),"open":g.open,"memberIDs":g.memberIDs,"steps":g.steps,"files":g.files,"added":g.added,"removed":g.removed,
    "reads":g.reads,"searches":g.searches,"pages":g.pages,"failures":g.failures,"running":g.running,"liveVerb":optional(g.liveVerb),"liveTarget":optional(g.liveTarget),
    "recentActivity":g.recentActivity.map{["id":$0.id,"verb":$0.verb,"target":$0.target,"running":$0.running,"failed":$0.failed]},
    "startedAtMs":optional(g.startedAtMs),"endedAtMs":optional(g.endedAtMs),"cost":optional(g.cost),"preview":optional(g.preview),
    "plain":g.plain,"verb":optional(g.verb),"subject":optional(g.subject)]}
func row(_ row:ChatDisplayItem)->[String:Any]{
    let kind:[String:Any]
    switch row.kind{
    case let .user(text):kind=["type":"user","text":text]
    case let .assistant(text,backend):kind=["type":"assistant","text":text,"backend":optional(backend)]
    case let .turnSeparator(backend):kind=["type":"turnSeparator","backend":backend]
    case let .handoff(to,brief):kind=["type":"handoff","to":to,"brief":brief]
    case let .thinking(text):kind=["type":"thinking","text":text]
    case let .tool(state):kind=["type":"tool","state":tool(state)]
    case let .edit(state):kind=["type":"edit","state":edit(state)]
    case let .attachment(file):kind=["type":"attachment","file":json(file)]
    case let .approval(approval):kind=["type":"approval","approval":json(approval)]
    case let .usage(input,output,cost):kind=["type":"usage","input":input,"output":output,"cost":optional(cost)]
    case let .failed(text):kind=["type":"failed","text":text]
    case let .group(g):kind=["type":"group","group":group(g)]
    case let .question(q):kind=["type":"question","question":["id":q.id,"question":q.question,"options":q.options,"multiple":q.multiple,
        "defaultAnswer":optional(q.defaultAnswer),"blocking":q.blocking,"answer":optional(q.answer),"delivery":optional(q.delivery)]]
    case let .changes(c):kind=["type":"changes","changes":["id":c.id,"files":c.files.map{["path":$0.path,"added":$0.added,"removed":$0.removed,"patches":$0.patches]}]]
    }
    return ["isSteer":row.isSteer,"id":row.id,"kind":kind,"lastSequence":optional(row.lastSequence),"groupID":optional(row.groupID),
        "plainStep":row.plainStep.map{String(describing:$0)} as Any? ?? NSNull(),"imageAttachments":json(row.imageAttachments),"imageRowIDs":row.imageRowIDs,"sourceBackend":optional(row.sourceBackend)]
}
func rows(_ input:[String:Any])->[ChatDisplayItem]{
    let events=try! JSONDecoder().decode([ChatTimelineEvent].self,from:JSONSerialization.data(withJSONObject:input["events"]!))
    return ChatDisplayItem.coalesce(events,defaultBackend:input["backend"] as? String,running:input["running"] as! Bool)
}
@main enum TranscriptReference{
    static func main() throws{
        let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [String:Any]
        let histories=(input["histories"] as! [[String:Any]]).map{input->[String:Any] in
            let raw=rows(input),presented=ChatAuthenticationFailure.presented(raw),prepared=ChatImageGrouping.prepare(presented),running=input["running"] as! Bool
            let folds=ChatDetail.allCases.flatMap{detail in ["closed","open","some"].map{mode->[String:Any] in
                let folded=ChatTranscriptFold.fold(prepared,detail:detail,running:running){mode=="open" || mode=="some" && $0.contains("tool")}
                let places=raw.map{["id":$0.id,"owner":optional(ChatTranscriptFold.owner(of:$0.id,in:folded)),"gallery":ChatImageGrouping.rowID(for:$0.id,in:prepared)]}
                return ["detail":detail.rawValue,"mode":mode,"rows":folded.map(row),"places":places]
            }}
            let recoveries=["claude","claude_code","cursor","cursor_agent","muse","codex"].map{backend->[String:Any] in
                let recovery=ChatAuthenticationFailure.latestRecovery(in:raw,backend:backend).map{["failureID":$0.failureID,"text":$0.text,"attachments":json($0.attachments)]}
                return ["backend":backend,"recovery":optional(recovery)]
            }
            return ["raw":raw.map(row),"presented":presented.map(row),"prepared":prepared.map(row),"folds":folds,"recoveries":recoveries]
        }
        let snippets=(input["snippets"] as! [[String:Any]]).map{v->[String:Any] in let text=v["text"] as! String
            return ["clip":ChatToolState.clip(text),"diff":ChatToolState.isDiffLine(text),"snippet":ChatToolState.makeSnippet(verb:v["verb"] as! String,detail:text)]}
        let questions=(input["questions"] as! [[String:Any]]).map{ChatQuestionText.stripping($0["text"] as! String,streaming:$0["streaming"] as! Bool)}
        let muse=(input["muse"] as! [[String:Any]]).map{v->[String:String] in
            let p=MuseToolPresentation.completed(backend:v["backend"] as? String,verb:v["verb"] as! String,target:v["target"] as! String,detail:v["detail"] as? String)
            return ["verb":p.verb,"target":p.target]}
        let clocks=(input["clocks"] as! [[Any]]).map{optional(ChatClock.duration(from:($0[0] as! NSNumber).int64Value,to:($0[1] as? NSNumber)?.int64Value))}
        let ordinals=(input["ordinals"] as! [NSNumber]).map{ChatClock.ordinal($0.intValue)}
        let previews=(input["previews"] as! [String]).map{optional(ChatTranscriptFold.preview(of:$0))}
        let equality=(input["equality"] as! [[[String:Any]]]).map{v->[String:Any] in
            let a=rows(v[0]),b=rows(v[1])
            return ["equal":a==b,"folded":ChatDetail.allCases.map{ChatTranscriptFold.fold(ChatImageGrouping.prepare(ChatAuthenticationFailure.presented(a)),detail:$0,running:false){_ in false} == ChatTranscriptFold.fold(ChatImageGrouping.prepare(ChatAuthenticationFailure.presented(b)),detail:$0,running:false){_ in false}}]
        }
        let auth=(input["auth"] as! [[String:String]]).map{ChatAuthenticationFailure.needsSignIn($0["text"]!,backend:$0["backend"]!)}
        let output:[String:Any]=["histories":histories,"snippets":snippets,"questions":questions,"muse":muse,"clocks":clocks,"ordinals":ordinals,"previews":previews,"equality":equality,"auth":auth]
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys]))
    }
}
