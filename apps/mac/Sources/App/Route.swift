// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" is a trademark of pueev OU. See TRADEMARK.md.

import SwiftUI

/// Where the shell is pointed.
///
/// Two scopes, one shape. Tasks, workflows and automations all already carry a
/// workspace on the host side, and the app used to show every one of them in a
/// single cross-project board because navigation was flat while the data was
/// not. A route says which scope you are in as well as which screen, so the
/// same screen can be the whole machine's list or one folder's.
///
/// See `docs/workspace-navigation.md`.
enum Route: Hashable {
    /// Machine-wide. The weekly question, and the screens that have no folder.
    case global(GlobalSection)
    /// One folder, one of its sections. The daily question.
    case workspace(id: String, section: WorkspaceSection)
    /// The SSH library, one of its sections.
    ///
    /// Its own case rather than a `GlobalSection`, because a global section is
    /// one screen and this is four screens plus a folder tree. Keeping it here
    /// also means every `switch route` in the shell has to answer for it, which
    /// is how the columns stay honest.
    case ssh(SSHSection)
    /// Every live session on one saved server, with its tabs and its split.
    ///
    /// A route rather than a presented cover, which is what it used to be. A
    /// cover meant one session at a time and closing it killed the shell. The
    /// sessions belong to the host process and outlive any screen, so the
    /// screen showing them has to be somewhere you can leave and come back to.
    ///
    /// Its own case and not an `SSHSection`, because a section is a list with
    /// an editor beside it and this is a terminal. Folding it in made six
    /// switches in the library answer for a case they can never be handed.
    case sshTerminals(host: String)

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

    /// The server whose sessions are in front, when that is what is in front.
    var sshTerminalHostID: String? {
        if case let .sshTerminals(host) = self { return host }
        return nil
    }

    /// Both halves of the SSH world. The sidebar group stays open for either.
    var isSSH: Bool { sshSection != nil || sshTerminalHostID != nil }

    /// True when this route is that global screen. Reads better at the call
    /// site than unwrapping the optional, and there are a lot of call sites.
    func isGlobal(_ section: GlobalSection) -> Bool { globalSection == section }

    /// Whether the trailing inspector column exists here.
    ///
    /// Account is the one screen with nothing to put beside it. Everything
    /// else has a panel, so the default is yes, and every SSH section says
    /// yes: the list is the content column and the editor is the inspector.
    ///
    /// Notes used to be the other exception, which is why a note's own text
    /// could be written and then never read again on a wide window while a
    /// task one list over had a whole pane for the same thing.
    var hasInspector: Bool {
        globalSection != .account
    }
}

/// The machine-wide screens.
enum GlobalSection: String, CaseIterable, Identifiable, Hashable {
    case home
    case insights
    case machines
    case todo
    case notes
    case workflows
    case automations
    /// Reached from the footer, not from a row.
    case account

    var id: String { rawValue }

    /// The rows in the sidebar's top group, in order.
    ///
    /// Home, Insights and Devices are the whole machine and stand alone at the
    /// top. Tasks, Workflows and Automations are the all-folders view of things
    /// that are usually asked about one folder at a time, so they sit under a
    /// GLOBAL heading rather than pretending to be the only view of themselves.
    static var standalone: [GlobalSection] { [.home, .insights, .machines] }
    static var everywhere: [GlobalSection] { [.todo, .notes, .workflows, .automations] }

    var label: String {
        switch self {
        case .home: return "Home"
        case .todo: return "Tasks"
        case .notes: return "Notes"
        case .automations: return "Automations"
        case .workflows: return "Workflows"
        case .machines: return "Devices"
        case .insights: return "Insights"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .home: return "square.grid.3x3.fill"
        case .todo: return "checklist"
        case .notes: return "note.text"
        case .automations: return "bolt.fill"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .machines: return "laptopcomputer"
        case .insights: return "chart.bar.xaxis"
        case .account: return "person.crop.circle"
        }
    }
}

/// The sections inside one workspace.
///
/// Fixed set, fixed order, shown for every folder whether or not they have
/// anything in them. A list that hides its empty rows moves under the cursor,
/// and a sidebar is worth having because it does not move.
enum WorkspaceSection: String, CaseIterable, Identifiable, Hashable {
    case sessions
    /// Talking to the agents in this folder, rather than driving them through
    /// a terminal. Nothing behind it yet, and it is here rather than waiting
    /// for the feature because a place people can see is a place they can ask
    /// about.
    case chat
    case changes
    case todo
    case notes
    case workflows
    case automations
    case files
    case browser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .chat: return "Chat"
        case .changes: return "Changes"
        case .todo: return "Tasks"
        case .notes: return "Notes"
        case .workflows: return "Workflows"
        case .automations: return "Automations"
        case .files: return "Files"
        case .browser: return "Browser"
        }
    }

    var symbol: String {
        switch self {
        case .sessions: return "terminal.fill"
        case .chat: return "bubble.left.and.bubble.right"
        case .changes: return "plusminus"
        case .todo: return "checklist"
        case .notes: return "note.text"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        case .automations: return "bolt.fill"
        case .files: return "folder.fill"
        case .browser: return "globe"
        }
    }
}

/// The sections of the SSH library.
///
/// Fixed set, fixed order, the same shape a workspace has. Hosts carries an
/// optional folder because the sidebar nests folders under it and a folder row
/// is that same screen filtered, not a screen of its own.
enum SSHSection: Hashable, Identifiable {
    case hosts(folder: String?)
    case keys
    case snippets
    case knownHosts

    /// The four rows, in order. `hosts` unfiltered, because the folders under
    /// it are drawn from the model rather than from this list.
    static var rows: [SSHSection] { [.hosts(folder: nil), .keys, .snippets, .knownHosts] }

    var id: String {
        switch self {
        case let .hosts(folder): return "hosts:\(folder ?? "")"
        case .keys: return "keys"
        case .snippets: return "snippets"
        case .knownHosts: return "knownHosts"
        }
    }

    /// The row this section lights up. A folder is inside Hosts, so it lights
    /// Hosts as well as its own row.
    var row: SSHSection {
        if case .hosts = self { return .hosts(folder: nil) }
        return self
    }

    /// Set when the route is one folder's worth of hosts.
    var folderID: String? {
        if case let .hosts(folder) = self { return folder }
        return nil
    }

    var label: String {
        switch self {
        case .hosts: return "Hosts"
        case .keys: return "Keys"
        case .snippets: return "Snippets"
        case .knownHosts: return "Trusted servers"
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

    /// The word an Add button uses. Singular, because it adds one.
    var addLabel: String {
        switch self {
        case .hosts: return "Add host"
        case .keys: return "Add key"
        case .snippets: return "Add snippet"
        case .knownHosts: return "Add server"
        }
    }
}

/// What a screen inside the app can ask the shell for.
///
/// Deliberately smaller than `Route`: a sheet three levels down knows it wants
/// Devices, or wants the workspace surface, and has no business deciding which
/// folder is selected or which section of it is in front.
enum NavigationRequest: Hashable {
    case global(GlobalSection)
    /// The SSH library, wherever it was last left. A card on Devices asks for
    /// "servers", not for "Keys": which section is the shell's business.
    case ssh
    /// The workspace surface, whichever folder is current.
    case workspaces
    /// That folder's launch grid. A setup hint uses this when the next
    /// step is to unhide an agent, not to reopen last week's Tasks board.
    case launcher
}
