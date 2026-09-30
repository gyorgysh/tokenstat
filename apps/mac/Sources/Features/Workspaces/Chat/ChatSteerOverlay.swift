// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

/// A list started before a note mutation cannot undo its acknowledgment.
/// Each account, host and project has independent reads and mutation boundaries.
struct ChatSteerOverlay {
    struct Read {
        let owner: String
        let sequence: UInt64
    }

    struct Mutation {
        let owner: String
        let conversationID: String
        let revision: UInt64
    }

    private struct Change {
        let note: String?
        let through: UInt64
    }

    private struct Project {
        var requested: UInt64 = 0
        var applied: UInt64 = 0
        var changes: [String: Change] = [:]
        var mutations: [String: UInt64] = [:]
    }

    private var projects: [String: Project] = [:]

    mutating func beginRead(owner: String) -> Read {
        var project = projects[owner] ?? Project()
        project.requested &+= 1
        projects[owner] = project
        return Read(owner: owner, sequence: project.requested)
    }

    func mutation(owner: String, conversationID: String) -> Mutation {
        Mutation(owner: owner, conversationID: conversationID,
                 revision: projects[owner]?.mutations[conversationID] ?? 0)
    }

    /// A removal started for an older note cannot retire a later acceptance,
    /// even when both notes have identical words or a fresh list retired its overlay.
    @discardableResult
    mutating func remember(owner: String, conversationID: String, note: String?,
                           ifUnchangedSince mutation: Mutation? = nil) -> Bool {
        var project = projects[owner] ?? Project()
        if let mutation {
            guard mutation.owner == owner, mutation.conversationID == conversationID,
                  mutation.revision == (project.mutations[conversationID] ?? 0) else { return false }
        }
        project.mutations[conversationID, default: 0] &+= 1
        project.changes[conversationID] = Change(note: note, through: project.requested)
        projects[owner] = project
        return true
    }

    mutating func apply(_ rows: [ChatConversation], read: Read, current: [ChatConversation]) -> [ChatConversation] {
        var project = projects[read.owner] ?? Project()
        guard read.sequence >= project.applied else { return current }
        project.applied = read.sequence
        var rows = rows
        let present = Set(rows.map(\.id))
        for index in rows.indices {
            let id = rows[index].id
            guard let change = project.changes[id] else { continue }
            // A request started after acknowledgment can show consumption or
            // a note from another client. That is fresh host state.
            if read.sequence > change.through {
                project.changes[id] = nil
            } else {
                rows[index].pendingSteer = change.note
            }
        }
        for (id, change) in project.changes where !present.contains(id) && read.sequence > change.through {
            project.changes[id] = nil
        }
        projects[read.owner] = project
        return rows
    }

    mutating func removeAll() { projects = [:] }

    /// Metadata and send replies are disk records. Only chat.list includes
    /// the ephemeral note, so its absence in a record is not a removal.
    static func preservingNote(in record: ChatConversation, from current: ChatConversation?) -> ChatConversation {
        guard let current, current.id == record.id else { return record }
        var record = record
        record.pendingSteer = current.pendingSteer
        return record
    }
}
