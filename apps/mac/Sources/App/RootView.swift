// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

import SwiftUI

/// The four top level destinations from the desktop plan.
///
/// Insights is the only one built. The rest are listed because the shape of the
/// product is the point: this is a workspace runner that happens to know what
/// everything costs, not a reporting tool that might grow a terminal.
enum Destination: String, CaseIterable, Identifiable {
    case insights
    case workspaces
    case automations
    case fleet
    case account

    var id: String { rawValue }

    /// Account sits apart from the rest: the others are the work, it is the
    /// settings for it.
    static var workDestinations: [Destination] {
        allCases.filter { $0 != .account }
    }

    var label: String {
        switch self {
        case .insights: return "Insights"
        case .workspaces: return "Workspaces"
        case .automations: return "Automations"
        case .fleet: return "Fleet"
        case .account: return "Account"
        }
    }

    var symbol: String {
        switch self {
        case .insights: return "chart.bar.fill"
        case .workspaces: return "square.stack.3d.up.fill"
        case .automations: return "bolt.fill"
        case .fleet: return "desktopcomputer"
        case .account: return "person.crop.circle"
        }
    }
}

struct RootView: View {
    @State private var destination: Destination = .insights
    @State private var model = InsightsModel()
    @State private var account = AccountModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .task { await model.load() }
        // Loaded up front, not on first visit, so the sidebar can show the
        // handle without the user opening the screen to populate it.
        .task { await account.load() }
    }

    private var sidebar: some View {
        List(selection: $destination) {
            Section {
                ForEach(Destination.workDestinations) { item in
                    Label(item.label, systemImage: item.symbol)
                        .tag(item)
                }
            }
            Section {
                Label {
                    // The handle when there is one: an account screen that does
                    // not say who is signed in makes you open it to find out.
                    Text(account.account?.handle.map { "@\($0)" } ?? Destination.account.label)
                } icon: {
                    Image(systemName: Destination.account.symbol)
                }
                .tag(Destination.account)
            }
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        .safeAreaInset(edge: .bottom) { archiveFooter }
    }

    /// Which archive is on screen, and when it was last read.
    ///
    /// A reporting tool that silently shows stale numbers is worse than one
    /// that shows none, so this is chrome rather than a detail view.
    private var archiveFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Divider()
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(model.info == nil ? Color.secondary : Theme.secondary)
                    .frame(width: 6, height: 6)
                Text(model.info.map { "Local archive · \($0.timezone)" } ?? "Opening archive…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.bottom, Theme.Space.s)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .insights:
            InsightsView(model: model)
        case .workspaces:
            NotBuiltYet(
                title: "Workspaces",
                symbol: "square.stack.3d.up",
                summary: """
                A folder per piece of work, with its branch, its diff, its file tree, \
                and the agent sessions running against it. Each row carries what it \
                has burned.
                """,
                milestone: "Milestone 4 in docs/desktop-app.md"
            )
        case .automations:
            NotBuiltYet(
                title: "Automations",
                symbol: "bolt",
                summary: """
                Recurring agent jobs that keep running with the window closed, \
                each with a budget it stops at rather than one it reports after.
                """,
                milestone: "Needs the host daemon, milestone 3"
            )
        case .fleet:
            NotBuiltYet(
                title: "Fleet",
                symbol: "desktopcomputer",
                summary: """
                Every machine signed in to your account, its workspaces, and its \
                sessions. This is what makes an iPad a client of your Mac rather \
                than a second place to read numbers.
                """,
                milestone: "Milestone 6, needs the remote transport decision"
            )
        case .account:
            AccountView(model: account)
        }
    }
}
