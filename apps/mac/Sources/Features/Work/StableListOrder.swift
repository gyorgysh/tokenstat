// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// Keep targets in place while a person is touching or pointing at a list.
/// Existing rows receive fresh values, vanished rows leave, and new rows
/// follow the held targets. Duplicate identifiers never reach a ForEach.
enum StableListOrder {
    static func holding<Item: Identifiable>(_ incoming: [Item], ids: [Item.ID]?) -> [Item] {
        var seen = Set<Item.ID>()
        let unique = incoming.filter { seen.insert($0.id).inserted }
        guard let ids else { return unique }
        let values = Dictionary(uniqueKeysWithValues: unique.map { ($0.id, $0) })
        seen.removeAll(keepingCapacity: true)
        let held = ids.compactMap { id -> Item? in
            guard seen.insert(id).inserted else { return nil }
            return values[id]
        }
        return held + unique.filter { !seen.contains($0.id) }
    }
}
