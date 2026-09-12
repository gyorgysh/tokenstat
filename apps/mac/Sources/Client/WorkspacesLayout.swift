// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import Foundation
import Observation

/// One block of the connected-host Workspaces surface.
///
/// Hosts and the security note stay outside this list: they are how you get
/// here, not cards to rearrange. Only Folders, Recent chats and All sessions
/// move, because that is the work someone opens the tab for once a machine
/// is already on the line.
enum WorkspacesSection: String, CaseIterable, Identifiable, Codable, Sendable {
    case folders
    case recentChats = "recent_chats"
    case sessions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .folders: "Folders"
        case .recentChats: "Recent chats"
        case .sessions: "All sessions"
        }
    }

    var detail: String {
        switch self {
        case .folders: "Projects on the connected computer"
        case .recentChats: "Chats opened recently"
        case .sessions: "Terminals and agents running now"
        }
    }

    var symbol: String {
        switch self {
        case .folders: "folder.fill"
        case .recentChats: "bubble.left.and.bubble.right.fill"
        case .sessions: "terminal.fill"
        }
    }
}

/// A starting arrangement for the three work blocks.
enum WorkspacesPreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case foldersFirst = "folders"
    case chatsFirst = "chats"
    case sessionsFirst = "sessions"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .foldersFirst: "Folders first"
        case .chatsFirst: "Chats first"
        case .sessionsFirst: "Sessions first"
        }
    }

    var order: [WorkspacesSection] {
        switch self {
        case .foldersFirst: [.folders, .recentChats, .sessions]
        case .chatsFirst: [.recentChats, .folders, .sessions]
        case .sessionsFirst: [.sessions, .folders, .recentChats]
        }
    }

    var hidden: Set<WorkspacesSection> { [] }
}

/// How this device arranges Folders / Recent chats / All sessions once a host
/// is connected.
///
/// Device furniture, same idea as Home: a phone and an iPad keep their own
/// order. The connected machine is one at a time; the layout is not per host.
@MainActor @Observable
final class WorkspacesLayout {
    static let shared = WorkspacesLayout()

    private static let orderKey = "workspaces.sectionOrder.v1"
    private static let hiddenKey = "workspaces.sectionHidden.v1"
    private static let presetKey = "workspaces.sectionPreset.v1"

    private(set) var order: [WorkspacesSection]
    private(set) var hidden: Set<WorkspacesSection>
    private(set) var preset: WorkspacesPreset?

    var sections: [WorkspacesSection] { order.filter { !hidden.contains($0) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Self.orderKey) == nil
            ? nil
            : defaults.stringArray(forKey: Self.orderKey)
        let resolved = Self.normalize(
            order: stored?.compactMap(WorkspacesSection.init(rawValue:)),
            hidden: (defaults.stringArray(forKey: Self.hiddenKey) ?? [])
                .compactMap(WorkspacesSection.init(rawValue:))
        )
        order = resolved.order
        hidden = resolved.hidden
        preset = stored == nil
            ? .foldersFirst
            : defaults.string(forKey: Self.presetKey).flatMap(WorkspacesPreset.init(rawValue:))
    }

    @ObservationIgnored private let defaults: UserDefaults

    static func normalize(
        order stored: [WorkspacesSection]?, hidden: [WorkspacesSection]
    ) -> (order: [WorkspacesSection], hidden: Set<WorkspacesSection>) {
        guard let stored else {
            return (WorkspacesPreset.foldersFirst.order, WorkspacesPreset.foldersFirst.hidden)
        }
        var seen: Set<WorkspacesSection> = []
        var order = stored.filter { seen.insert($0).inserted }
        order += WorkspacesPreset.foldersFirst.order.filter { !seen.contains($0) }
        return (order, Set(hidden).intersection(order))
    }

    static func moved(
        _ sections: [WorkspacesSection], from offsets: IndexSet, to destination: Int
    ) -> [WorkspacesSection] {
        let lifted = offsets.sorted().filter { sections.indices.contains($0) }
        guard !lifted.isEmpty else { return sections }
        let moving = lifted.map { sections[$0] }
        var remaining = sections
        for index in lifted.reversed() { remaining.remove(at: index) }
        let ahead = lifted.filter { $0 < destination }.count
        let target = min(max(0, destination - ahead), remaining.count)
        remaining.insert(contentsOf: moving, at: target)
        return remaining
    }

    static func movedVisible(
        _ order: [WorkspacesSection],
        hidden: Set<WorkspacesSection>,
        from offsets: IndexSet,
        to destination: Int
    ) -> [WorkspacesSection] {
        let visible = order.filter { !hidden.contains($0) }
        var moved = moved(visible, from: offsets, to: destination).makeIterator()
        return order.map { hidden.contains($0) ? $0 : moved.next() ?? $0 }
    }

    func apply(order: [WorkspacesSection], hidden: Set<WorkspacesSection>, preset: WorkspacesPreset?) {
        let resolved = Self.normalize(order: order, hidden: Array(hidden))
        self.order = resolved.order
        self.hidden = resolved.hidden
        self.preset = preset
        save()
    }

    func reset() {
        apply(
            order: WorkspacesPreset.foldersFirst.order,
            hidden: WorkspacesPreset.foldersFirst.hidden,
            preset: .foldersFirst
        )
    }

    private func save() {
        defaults.set(order.map(\.rawValue), forKey: Self.orderKey)
        defaults.set(hidden.map(\.rawValue), forKey: Self.hiddenKey)
        if let preset {
            defaults.set(preset.rawValue, forKey: Self.presetKey)
        } else {
            defaults.removeObject(forKey: Self.presetKey)
        }
    }
}
