// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

// The complete original stores are compiled beside this harness. Every instance
// receives a newly allocated temporary directory; the shared singleton is unused.
import Foundation

enum L10n {
    static func text(_ key: String) -> String { key }
}

@main struct DraftStoreReference {
    static func decode<T: Decodable>(_ type: T.Type, _ raw: Any) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: raw))
    }

    static func normalize(_ raw: Any, ids: inout [String: String]) -> Any {
        if var object = raw as? [String: Any] {
            if let id = object["messageId"] as? String, UUID(uuidString: id) != nil {
                if ids[id] == nil { ids[id] = "UUID-\(ids.count + 1)" }
                object["messageId"] = ids[id]!
            }
            for key in object.keys.sorted() { object[key] = normalize(object[key]!, ids: &ids) }
            return object
        }
        if let array = raw as? [Any] { return array.map { normalize($0, ids: &ids) } }
        return raw
    }

    @MainActor static func records(_ store: ChatDraftStore, _ references: [WorkReference]) -> [String: ChatDraft] {
        var result: [String: ChatDraft] = [:]
        for reference in references {
            if let key = WorkReferenceKey.conversation(reference), let draft = store.draft(for: reference) {
                result[key] = draft
            }
        }
        return result
    }

    @MainActor static func snapshot(_ stores: [ChatDraftStore], _ references: [WorkReference],
                                    _ root: URL, settled: Bool, ids: inout [String: String]) throws -> [String: Any] {
        var rows: [[String: Any]] = []
        for store in stores {
            let data = try JSONEncoder().encode(records(store, references))
            var protection: Any = "pending"
            if settled {
                do {
                    let scopes = try references.map { reference in
                        try store.protectedAttachments(in: reference.scope).mapValues { $0.sorted() }
                    }
                    let referenced = try references.map { try store.referencedAttachmentIDs(for: $0).sorted() }
                    protection = ["scopes": scopes, "references": referenced]
                } catch { protection = "failed" }
            }
            rows.append(["records": normalize(try JSONSerialization.jsonObject(with: data), ids: &ids),
                         "occupied": store.occupied.sorted(), "failed": store.saveFailed,
                         "memoryBytes": data.count, "has": references.map { store.hasDraft(for: $0) },
                         "protection": protection])
        }
        var disk: Any = "pending"
        if settled {
            let file = root.appendingPathComponent("drafts.v1.json")
            if FileManager.default.fileExists(atPath: file.path) {
                let data = try Data(contentsOf: file)
                if let object = try? JSONSerialization.jsonObject(with: data) {
                    disk = ["records": normalize(object, ids: &ids), "bytes": data.count]
                } else { disk = "invalid" }
            } else { disk = NSNull() }
        }
        return ["stores": rows, "disk": disk]
    }

    @MainActor static func run(_ input: [String: Any]) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tokenstat-draft-reference-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        if let seed = input["seed"] as? String {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(seed.utf8).write(to: root.appendingPathComponent("drafts.v1.json"))
        }
        let references = try decode([WorkReference].self, input["references"]!)
        let limit = input["limit"] as! Int
        var stores = [ChatDraftStore(directory: root, byteLimit: limit)]
        stores[0].settle()
        var expected: [String: ChatDraft] = [:], ids: [String: String] = [:]
        var rows = [try snapshot(stores, references, root, settled: true, ids: &ids)]
        for step in input["steps"] as! [[String: Any]] {
            let index = step["store"] as? Int ?? 0
            let reference = (step["ref"] as? Int).map { references[$0] }
            switch step["op"] as! String {
            case "open":
                let store = ChatDraftStore(directory: root, byteLimit: limit)
                store.settle(); stores.append(store)
            case "save":
                stores[index].save(text: step["text"] as! String,
                                   attachments: try decode([ChatAttachment].self, step["attachments"] ?? []),
                                   for: reference!, at: Date(timeIntervalSinceReferenceDate: (step["at"] as? NSNumber)?.doubleValue ?? 0),
                                   newMessage: step["new"] as? Bool ?? false)
            case "clear": stores[index].clear(for: reference!)
            case "remember": expected[step["name"] as! String] = stores[index].draft(for: reference!)!
            case "clearExpected": stores[index].clear(expected[step["name"] as! String]!)
            case "retry": stores[index].retryFailedSave()
            case "corrupt":
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data((step["bytes"] as! String).utf8).write(to: root.appendingPathComponent("drafts.v1.json"))
            case "settle": break
            default: fatalError("Unknown fixture operation")
            }
            let settled = step["settle"] as? Bool ?? true
            if settled { for store in stores { store.settle() } }
            rows.append(try snapshot(stores, references, root, settled: settled, ids: &ids))
        }
        for store in stores { store.settle() }
        return ["input": input, "rows": rows]
    }

    static func reference(_ id: String) -> WorkReference {
        WorkReference(scope: .local(installationID: "fixture"), hostIdentity: "host", workspaceID: "folder",
                      kind: .conversation, itemID: id)
    }

    @MainActor static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count >= 2 {
            let root = URL(fileURLWithPath: args[1], isDirectory: true)
            switch args[0] {
            case "writer":
                let store = ChatDraftStore(directory: root)
                for index in 0..<25 {
                    let id = "\(args[2])-\(index)"
                    store.save(text: id, attachments: [], for: reference(id), at: Date(timeIntervalSinceReferenceDate: Double(index)))
                    store.settle(); precondition(!store.saveFailed)
                }
                return
            case "read":
                let store = ChatDraftStore(directory: root)
                store.settle(); precondition(!store.saveFailed)
                let refs = ["rust", "swift"].flatMap { author in (0..<25).map { reference("\(author)-\($0)") } }
                print(String(data: try JSONEncoder().encode(records(store, refs)), encoding: .utf8)!)
                return
            case "participant":
                let participant = try OriginalFileCoordination.join(directory: root)
                try Data("ready".utf8).write(to: root.appendingPathComponent("ready-swift"))
                withExtendedLifetime(participant) { _ = FileHandle.standardInput.readData(ofLength: 1) }
                return
            case "sole":
                let participant = try OriginalFileCoordination.join(directory: root)
                let allowed = (try? OriginalFileCoordination.whileSoleParticipant(participant, removing: root.appendingPathComponent("original")) { true }) ?? false
                print(allowed ? "{\"allowed\":true}" : "{\"allowed\":false}")
                return
            default: fatalError("Unknown fixture mode")
            }
        }
        let cases = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [[String: Any]]
        let output = try cases.map { try run($0["input"] as! [String: Any]) }
        print(String(data: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
