// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// Original stores run against this private in-memory defaults adapter. The
// real UserDefaults.standard domain is never constructed or accessed.
import Foundation
import Observation

enum WorkStorageReference {
    final class Defaults {
        static let standard = Defaults()
        var values: [String:Data] = [:]
        func data(forKey key: String) -> Data? { values[key] }
        func set(_ data: Data,forKey key: String) { values[key]=data }
        func removeObject(forKey key: String) { values.removeValue(forKey:key) }
    }
    enum WorkCache {
        /* SOURCE_SCOPE_KEY */
    }
    /* SOURCE_PINS */
    /* SOURCE_CONTINUITY */

    @MainActor static func state(_ defaults: Defaults,_ scopes: [WorkReference.Scope]) -> [String:Any] {
        let pins=PinnedWorkStore(defaults:defaults), continuity=WorkContinuityStore(defaults:defaults)
        let place=continuity.place()
        let shelves=scopes.map { scope in
            ["scope":scopeJSON(scope),"pins":pins.pins(in:scope).map { pin in
                ["reference":referenceJSON(pin.reference),"label":pin.label,"folderName":pin.folderName,"pinnedAt":pin.pinnedAt.timeIntervalSinceReferenceDate] as [String:Any]
             },"recent":continuity.recentConversations(scope:scope).map(referenceJSON),"negative":continuity.recentConversations(scope:scope,limit:-1).map(referenceJSON),"last":continuity.lastConversation(scope:scope,hostIdentity:"host",workspaceID:"a").map(referenceJSON) as Any? ?? NSNull()] as [String:Any]
        }
        let ids=["a","remote:peer:a","é","remote:peer:é"]
        return ["shelves":shelves,"place":place.map(placeJSON) as Any? ?? NSNull(),"restored":scopes.map { destinationJSON(WorkPlaceRestoration.destination(place:place,folderIDs:ids,scope:$0,localHostIdentity:"host")) },"unknownRestore":destinationJSON(WorkPlaceRestoration.destination(place:place,folderIDs:ids,scope:nil,localHostIdentity:"host")),"keys":defaults.values.keys.sorted()]
    }
    @MainActor static func run(_ input: [String:Any]) throws -> [String:Any] {
        let defaults=Defaults()
        for (key,value) in input["seed"] as? [String:String] ?? [:] { defaults.values[key]=Data(value.utf8) }
        let scopes=try decode([WorkReference.Scope].self,input["scopes"]!)
        var rows: [[String:Any]]=[["label":"initial","result":NSNull(),"state":state(defaults,scopes)]]
        for step in input["steps"] as! [[String:Any]] {
            let pins=PinnedWorkStore(defaults:defaults), continuity=WorkContinuityStore(defaults:defaults)
            let at=Date(timeIntervalSinceReferenceDate:step["atMode"] as? String == "nan" ? .nan : (step["at"] as? NSNumber)?.doubleValue ?? 0)
            func reference() throws -> WorkReference { try decode(WorkReference.self,step["reference"]!) }
            func scope() throws -> WorkReference.Scope { try decode(WorkReference.Scope.self,step["scope"]!) }
            var result: Any=NSNull()
            switch step["op"] as! String {
            case "pin": result=pins.pin(try reference(),label:step["label"] as? String ?? "label",folderName:step["folderName"] as? String ?? "folder",at:at)
            case "unpin": pins.unpin(try reference())
            case "remember": continuity.remember(try reference(),at:at)
            case "forget": continuity.forget(scope:try scope(),hostIdentity:step["host"] as! String,workspaceID:step["workspace"] as! String)
            case "remove": continuity.remove(scope:try scope())
            case "place":
                var place=try decode(WorkPlace.self,step["place"]!)
                if step["atMode"] as? String == "nan" { place.savedAt=at }
                continuity.rememberPlace(place)
            case "forgetPlace": continuity.forgetPlace()
            default: fatalError("Unknown fixture operation")
            }
            if step["report"] as? Bool != false { rows.append(["label":step["name"]!,"result":result,"state":state(defaults,scopes)]) }
        }
        return ["input":input,"rows":rows]
    }
    @MainActor static func snapshot(_ raw: String) throws -> [String:Any] {
        let input=try JSONSerialization.jsonObject(with:Data(raw.utf8)) as! [String:Any]
        let scopes=(input["scopes"] as! [[String:Any]]).map { row -> [String:Any] in
            let scope=WorkReference.Scope.account(origin:row["origin"] as! String,handle:row["identity"] as! String)
            return ["origin":row["origin"]!,"identity":row["identity"]!,"scope":scope.map(scopeJSON) as Any? ?? NSNull(),"key":scope.map { WorkCache.scope(for:$0) } as Any? ?? NSNull()]
        }
        let labels=(input["labels"] as! [[String:Any]]).map { row -> [String:Any] in
            let label=row["input"] as! String
            // Observe safeLabel through the actual store's public operation.
            let store=PinnedWorkStore(defaults:Defaults())
            let local=WorkReference.Scope.local(installationID:"fixture")
            let ref=WorkReference(scope:local,hostIdentity:"host",workspaceID:"folder",kind:.workspace,itemID:nil)
            store.pin(ref,label:label,folderName:label,at:Date(timeIntervalSinceReferenceDate:0))
            return ["input":label,"safe":store.pins(in:local)[0].label,"encoded":WorkReferenceKey.encode(label)]
        }
        let keys=try (input["keys"] as! [[String:Any]]).map { row -> [String:Any] in
            let ref=try decode(WorkReference.self,row["reference"]!)
            return ["reference":row["reference"]!,"pin":PinnedWorkStore.pinKey(for:ref) as Any? ?? NSNull(),"conversation":WorkReferenceKey.conversation(ref) as Any? ?? NSNull(),"folder":WorkReferenceKey.folder(scope:ref.scope,hostIdentity:ref.hostIdentity,workspaceID:ref.workspaceID)]
        }
        let cases=try (input["cases"] as! [[String:Any]]).map { try run($0["input"] as! [String:Any]) }
        return ["scopes":scopes,"labels":labels,"keys":keys,"cases":cases]
    }
    private static func decode<T:Decodable>(_ type: T.Type,_ raw: Any) throws -> T { try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:raw)) }
    private static func scopeJSON(_ scope: WorkReference.Scope) -> [String:Any] { ["kind":scope.kind.rawValue,"origin":scope.origin,"identity":scope.identity] }
    private static func placeJSON(_ place: WorkPlace) -> [String:Any] { ["globalSection":place.globalSection as Any? ?? NSNull(),"folder":place.folder.map(referenceJSON) as Any? ?? NSNull(),"folderSection":place.folderSection as Any? ?? NSNull(),"savedAt":place.savedAt.timeIntervalSinceReferenceDate] }
    private static func destinationJSON(_ destination: WorkPlaceRestoration.Destination?) -> Any {
        switch destination {
        case .global(let section)?: return ["kind":"global","section":section]
        case .workspace(let folder,let section)?: return ["kind":"workspace","folder":folder,"section":section]
        case nil: return NSNull()
        }
    }
}
