// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

import Foundation

/// One chat drawn in the chat-centric sidebar list.
struct SidebarChatEntry: Identifiable, Hashable, Sendable {
    let folder: WorkspaceFolder
    let conversation: ChatConversation

    var id: String { "\(folder.id)\u{1f}\(conversation.id)" }

    var activityMs: Int64 {
        conversation.lastMessageAtMs ?? conversation.updatedAtMs
    }
}

/// Which heading a chat sits under in the chat list.
enum SidebarChatDay: Hashable, Sendable {
    /// A turn is running right now. Drawn first, whatever its date.
    case working
    case today
    case yesterday
    /// Start of a calendar day within `SidebarProjectsLayout.olderAfterDays`.
    case day(Date)
    case older

    var id: String {
        switch self {
        case .working: return "working"
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .day(let date): return "day:\(Int64(date.timeIntervalSince1970))"
        case .older: return "older"
        }
    }
}

/// One dated heading and the chats under it.
struct SidebarChatDayGroup: Identifiable, Sendable {
    let day: SidebarChatDay
    let entries: [SidebarChatEntry]

    var id: String { day.id }
}

/// Pure layout helpers for the Repositories sidebar. Kept free of SwiftUI so
/// the filter, sort and view-mode rules can be checked without a window.
enum SidebarProjectsLayout {
    static func matches(_ query: String, folder: WorkspaceFolder, chats: [ChatConversation]) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        if folderMatches(needle, folder) { return true }
        return chats.contains { conversationMatches(needle, $0) }
    }

    static func matches(_ query: String, conversation: ChatConversation) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return true }
        return conversationMatches(needle, conversation)
    }

    static func filteredChats(_ chats: [ChatConversation], query: String) -> [ChatConversation] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return chats }
        return chats.filter { conversationMatches(needle, $0) }
    }

    static func orderedFolders(
        _ folders: [WorkspaceFolder],
        sort: SidebarProjectsSort,
        activity: (WorkspaceFolder) -> Int64
    ) -> [WorkspaceFolder] {
        switch sort {
        case .manual:
            return folders
        case .name:
            return folders.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        case .recent:
            return folders.sorted {
                let left = activity($0)
                let right = activity($1)
                if left != right { return left > right }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
    }

    static func chatEntries(
        folders: [WorkspaceFolder],
        chats: (WorkspaceFolder) -> [ChatConversation],
        query: String,
        sort: SidebarProjectsSort
    ) -> [SidebarChatEntry] {
        let needle = normalized(query)
        var entries: [SidebarChatEntry] = []
        for folder in folders {
            let list = chats(folder)
            let folderHit = !needle.isEmpty && folderMatches(needle, folder)
            for conversation in list {
                if needle.isEmpty || folderHit || conversationMatches(needle, conversation) {
                    entries.append(SidebarChatEntry(folder: folder, conversation: conversation))
                }
            }
        }
        switch sort {
        case .manual, .recent:
            return entries.sorted {
                if $0.conversation.running != $1.conversation.running {
                    return $0.conversation.running && !$1.conversation.running
                }
                if $0.activityMs != $1.activityMs { return $0.activityMs > $1.activityMs }
                return $0.conversation.title.localizedStandardCompare($1.conversation.title)
                    == .orderedAscending
            }
        case .name:
            return entries.sorted {
                let title = $0.conversation.title.localizedStandardCompare($1.conversation.title)
                if title != .orderedSame { return title == .orderedAscending }
                return $0.folder.name.localizedStandardCompare($1.folder.name) == .orderedAscending
            }
        }
    }

    /// Chats drawn before "Show more", and how many more each press adds.
    static let chatPageSize = 30
    /// Past this many days, chats share one Older heading instead of a day each.
    static let olderAfterDays = 7

    /// Splits recency-ordered entries into dated headings, keeping their order.
    /// Running chats lead under their own heading so live work stays on top.
    static func dayGroups(
        _ entries: [SidebarChatEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SidebarChatDayGroup] {
        let today = calendar.startOfDay(for: now)
        var order: [SidebarChatDay] = []
        var buckets: [SidebarChatDay: [SidebarChatEntry]] = [:]
        for entry in entries {
            let day = day(for: entry, today: today, calendar: calendar)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(entry)
        }
        // Entries arrive running-first, then newest first, so first sight
        // order is already Working, Today, Yesterday, dates, Older.
        return order.map { SidebarChatDayGroup(day: $0, entries: buckets[$0] ?? []) }
    }

    private static func day(for entry: SidebarChatEntry, today: Date, calendar: Calendar) -> SidebarChatDay {
        if entry.conversation.running { return .working }
        let date = Date(timeIntervalSince1970: TimeInterval(entry.activityMs) / 1000)
        let start = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? 0
        switch days {
        case ...0: return .today
        case 1: return .yesterday
        case ..<olderAfterDays: return .day(start)
        default: return .older
        }
    }

    private static func folderMatches(_ needle: String, _ folder: WorkspaceFolder) -> Bool {
        if contains(folder.name, needle) { return true }
        if let machine = folder.machineLabel, contains(machine, needle) { return true }
        return false
    }

    private static func conversationMatches(_ needle: String, _ conversation: ChatConversation) -> Bool {
        if contains(conversation.title, needle) { return true }
        if let branch = conversation.branch, contains(branch, needle) { return true }
        return contains(conversation.backend, needle)
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
