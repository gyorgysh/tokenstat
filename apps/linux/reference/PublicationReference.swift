// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

enum Caller { @TaskLocal static var id = "seed" }
@MainActor final class Gate {
    let actual = ChatTranscriptProjector()
    var automatic = true
    var attempts: [String:Int] = [:]
    var waiting: [String:([ChatDisplayItem],CheckedContinuation<[ChatDisplayItem],Error>)] = [:]
    func project(_ events:[ChatTimelineEvent],backend:String?,running:Bool) async throws -> [ChatDisplayItem] {
        let rows = try await actual.project(events,backend:backend,running:running)
        if automatic { return rows }
        let id = Caller.id
        attempts[id,default:0] += 1
        return try await withCheckedThrowingContinuation {waiting[id]=(rows,$0)}
    }
    func deliver(_ id:String) {let held=waiting.removeValue(forKey:id)!;held.1.resume(returning:held.0)}
}
@MainActor extension PagingModel {
    func changed(_ action:[String:Any]) {
        if let backend=action["backend"] as? String {selected?.backend=backend}
        if let running=action["running"] as? Bool {selected?.running=running}
        if let revision=action["revision"] as? NSNumber {selected?.sendRevision=revision.uint64Value}
    }
    func perform(_ action:[String:Any]) async {
        let id=selected!.id,generation=selectionGeneration
        switch action["kind"] as! String {
        case "metadata": _ = await publishEvents(id:id,generation:generation,recordsChanged:false){$0}
        case "earlier": await loadEarlier(id:id,generation:generation,quiet:false)
        case "tail": _ = await loadEvents(id:id,reset:false,generation:generation,quiet:false)
        case "open":
            openingConversation=true
            _ = await openEvents(id:id,generation:generation,quiet:false)
            if generation==selectionGeneration {openingConversation=false}
        default: fatalError("unknown kind")
        }
    }
}
@main enum PublicationReference {
    @MainActor static func until(_ condition:()->Bool) async {
        for _ in 0..<100_000 {if condition(){return};await Task.yield()}
        preconditionFailure("owned projection did not reach its expected continuation")
    }
    @MainActor static func main() async throws {
        let input=try JSONSerialization.jsonObject(with:FileHandle.standardInput.readDataToEndOfFile()) as! [String:Any]
        var traces:[[[String:Any]]]=[]
        for trace in input["traces"] as! [[String:Any]] {
            let model=PagingModel();Bridge.model=model;Bridge.calls=[]
            model.selectFixture("first",fresh:false)
            Bridge.responses=[["value":trace["seed"]!]]
            _ = await model.openEvents(id:"first",generation:model.selectionGeneration)
            model.openingConversation=false;model.transcriptProjector.automatic=false
            var tasks:[String:Task<Void,Never>]=[:],finished=Set<String>(),kinds:[String:String]=[:],checkpoints:[[String:Any]]=[]
            for action in trace["actions"] as! [[String:Any]] {
                switch action["op"] as! String {
                case "start":
                    let id=action["id"] as! String
                    kinds[id]=action["kind"] as? String
                    if action["kind"] as? String != "metadata" {Bridge.responses=[["value":action["value"]!]]}
                    tasks[id]=Task {await Caller.$id.withValue(id){await model.perform(action)};finished.insert(id)}
                    await until {model.transcriptProjector.waiting[id] != nil || finished.contains(id)}
                case "deliver":
                    let id=action["id"] as! String
                    model.transcriptProjector.deliver(id)
                    await until {model.transcriptProjector.waiting[id] != nil || finished.contains(id)}
                case "cancel":
                    let id=action["id"] as! String;tasks[id]!.cancel();model.transcriptProjector.deliver(id)
                    await until {finished.contains(id)}
                case "metadata":
                    let old=model.selected
                    model.changed(action)
                    if old?.backend != model.selected?.backend || old?.running != model.selected?.running {
                        for (id,kind) in kinds where kind=="metadata" {tasks[id]?.cancel()}
                    }
                case "select": model.selectFixture(action["id"] as! String,fresh:false)
                default: fatalError("unknown action")
                }
                let jobs=tasks.keys.sorted().map{["id":$0,"attempts":model.transcriptProjector.attempts[$0] ?? 0,"pending":!finished.contains($0)] as [String:Any]}
                checkpoints.append(["events":json(model.events),"rows":model.displayCache.map(row),"eventsRevision":model.eventsRevision,"displayRevision":model.displayRevision,
                    "selected":model.selected!.id,"backend":model.selected!.backend,"running":model.selected!.running,"offset":model.offset,
                    "tailCursor":optional(model.tailCursor),"earlierCursor":optional(model.earlierCursor),"hasEarlier":model.hasEarlier,
                    "opening":model.openingConversation,"loadingEarlier":model.loadingEarlier,"contextRevision":optional(model.contextRevision),
                    "usage":model.conversationUsage.map(json) as Any? ?? NSNull(),"jobs":jobs,"calls":Bridge.calls])
            }
            precondition(model.transcriptProjector.waiting.isEmpty && finished.count==tasks.count,"trace left a suspended task")
            traces.append(checkpoints)
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:["traces":traces],options:[.sortedKeys]))
    }
}
