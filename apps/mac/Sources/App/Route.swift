// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Store and commercial distribution of builds is reserved. See LICENSE.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

enum Route: Hashable {
    case global(GlobalSection)
    case workspace(id: String, section: WorkspaceSection)
    case workspacesOverview
    case ssh(SSHSection)
    case sshTerminals(host: String)

    var diagnosticName: String {
        switch self {
        case let .global(section): "\(section)"
        case let .workspace(_, section): "workspace.\(section)"
        case .workspacesOverview: "workspaces"
        case let .ssh(section): "ssh.\(section)"
        case .sshTerminals: "ssh.terminals"
        }
    }

    var globalSection: GlobalSection? {
        if case let .global(section) = self { return section }
        return nil
    }

    var workspaceID: String? {
        if case let .workspace(id, _) = self { return id }
        return nil
    }

    var workspaceSection: WorkspaceSection? {
        if case let .workspace(_, section) = self { return section }
        return nil
    }

    var sshSection: SSHSection? {
        if case let .ssh(section) = self { return section }
        return nil
    }

    var isWorkspace: Bool { workspaceID != nil }

    var sshTerminalHostID: String? {
        if case let .sshTerminals(host) = self { return host }
        return nil
    }

    var isSSH: Bool { sshSection != nil || sshTerminalHostID != nil }

    func isGlobal(_ section: GlobalSection) -> Bool { globalSection == section }

    var hasInspector: Bool {
        #if os(macOS)
        globalSection != .team && globalSection != .account && globalSection != .newChat && globalSection != .notes && workspaceSection != .notes
        #else
        globalSection != .team && globalSection != .account && globalSection != .newChat
        #endif
    }
}

enum GlobalSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case team
    case newChat
    case insights
    case machines
    case todo
    case notes
    case workflows
    case automations
    case account

    var id: String { rawValue }

    static var standalone: [GlobalSection] { [.home, .insights, .machines] }
    static var everywhere: [GlobalSection] { [.todo, .notes, .workflows, .automations] }

    var label: String {
        switch self {
        case .home: return L10n.text("common.home")
        case .newChat: return L10n.text("apple.rootview.new_chat.db18382a")
        case .todo: return L10n.text("common.tasks")
        case .notes: return L10n.text("common.notes")
        case .automations: return L10n.text("common.automations")
        case .workflows: return L10n.text("common.workflows")
        case .machines: return L10n.text("common.devices")
        case .insights: return L10n.text("common.insights")
        case .team: return L10n.text("common.teams.title")
        case .account: return L10n.text("common.account")
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.3x3.fill"
        case .newChat: return "square.and.pencil"
        case .todo: return "checklist"
        case .notes: return "note.text"
        case .automations: return "bolt.fill"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .machines: return "laptopcomputer"
        case .insights: return "chart.bar.xaxis"
        case .team: return "person.2"
        case .account: return "person.crop.circle"
        }
    }
}

enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case sessions
    case chat
    case changes
    case history
    case pulls
    case todo
    case notes
    case workflows
    case automations
    case files
    case browser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return L10n.text("common.terminals")
        case .chat: return L10n.text("common.chats")
        case .changes: return L10n.text("apple.route.changes.bbd4b6a8")
        case .history: return L10n.text("common.history")
        case .pulls: return L10n.text("apple.route.pull_requests.d9e3f260")
        case .todo: return L10n.text("common.tasks")
        case .notes: return L10n.text("common.notes")
        case .workflows: return L10n.text("common.workflows")
        case .automations: return L10n.text("common.automations")
        case .files: return L10n.text("common.files")
        case .browser: return L10n.text("common.browser")
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "terminal.fill"
        case .chat: return "bubble.left.and.bubble.right"
        case .changes: return "plusminus"
        case .history: return "clock.arrow.circlepath"
        case .pulls: return "arrow.triangle.merge"
        case .todo: return "checklist"
        case .notes: return "note.text"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .automations: return "bolt.fill"
        case .files: return "folder.fill"
        case .browser: return "globe"
        }
    }
}

enum SSHSection: Hashable, Identifiable {
    case hosts(folder: String?)
    case keys
    case snippets
    case knownHosts

    static var rows: [SSHSection] { [.hosts(folder: nil), .keys, .snippets, .knownHosts] }

    var id: String {
        switch self {
        case let .hosts(folder): return "hosts:\(folder ?? "")"
        case .keys: return "keys"
        case .snippets: return "snippets"
        case .knownHosts: return "knownHosts"
        }
    }

    var row: SSHSection {
        if case .hosts = self { return .hosts(folder: nil) }
        return self
    }

    var folderID: String? {
        if case let .hosts(folder) = self { return folder }
        return nil
    }

    var label: String {
        switch self {
        case .hosts: return L10n.text("apple.route.hosts.bba9af13")
        case .keys: return L10n.text("apple.route.keys.f0d66a79")
        case .snippets: return L10n.text("apple.route.snippets.ff717209")
        case .knownHosts: return L10n.text("apple.route.trusted_servers.b101ed86")
        }
    }

    var symbol: String {
        switch self {
        case .hosts: return "server.rack"
        case .keys: return "key.fill"
        case .snippets: return "text.badge.plus"
        case .knownHosts: return "checkmark.shield"
        }
    }

    var addLabel: String {
        switch self {
        case .hosts: return L10n.text("apple.route.add_host.7da3f6f4")
        case .keys: return L10n.text("apple.route.add_key.12626d65")
        case .snippets: return L10n.text("apple.route.add_snippet.a1f802b9")
        case .knownHosts: return L10n.text("apple.route.add_server.1099b2a9")
        }
    }
}

enum NavigationRequest: Hashable {
    case global(GlobalSection)
    case ssh
    case workspaces
    case workspacesOverview
    case launcher
}
