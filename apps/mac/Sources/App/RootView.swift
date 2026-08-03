// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

import SwiftUI

/// The top level destinations from the desktop plan.
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
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .inspector(isPresented: inspectorBinding) {
                    InspectorView(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
        }
        .task { await model.load() }
        // Loaded up front, not on first visit, so the sidebar can show the
        // handle without the user opening the screen to populate it.
        .task { await account.load() }
    }

    /// The inspector describes a report, so it only exists on Insights. Bound
    /// through a computed binding rather than hidden, so toggling it on one
    /// screen does not silently change another.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showInspector && destination == .insights },
            set: { showInspector = $0 }
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Workspace")
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.s)
                    .padding(.bottom, Theme.Space.xs)

                ForEach(Destination.workDestinations) { item in
                    SidebarRow(
                        label: item.label,
                        symbol: item.symbol,
                        isSelected: destination == item
                    ) { destination = item }
                }

                // Tools come from the archive, so this list is the set of
                // agents actually in use on this machine rather than a
                // catalogue of what tokenstat could read.
                SectionLabel(text: "Tools", count: model.bySource.count)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)

                if model.bySource.isEmpty {
                    Text("Run a scan to see your tools.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.xs)
                } else {
                    ForEach(model.bySource) { row in
                        SidebarRow(
                            label: row.key.isEmpty ? "unknown" : row.key,
                            symbol: "circle.fill",
                            symbolSize: 6,
                            trailing: formatTokens(row.counters.total),
                            isSelected: destination == .insights
                                && model.tab == .tools
                                && model.selected?.key == row.key
                        ) {
                            destination = .insights
                            model.tab = .tools
                            model.selected = row
                        }
                    }
                }

                SectionLabel(text: "Account")
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)

                SidebarRow(
                    label: account.account?.handle.map { "@\($0)" } ?? "Not signed in",
                    symbol: Destination.account.symbol,
                    isSelected: destination == .account
                ) { destination = .account }
            }
            .padding(.bottom, Theme.Space.m)
        }
        .background(Theme.sidebar)
        .navigationSplitViewColumnWidth(min: 190, ideal: 214, max: 280)
        .safeAreaInset(edge: .bottom) { archiveFooter }
    }

    /// Which archive is on screen. A reporting tool that silently shows stale
    /// numbers is worse than one that shows none, so this is chrome rather
    /// than a detail view.
    private var archiveFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: Theme.Space.s) {
                Circle()
                    .fill(model.info == nil ? Color.secondary : Theme.secondary)
                    .frame(width: 6, height: 6)
                Text(model.info.map { "Local archive · \($0.timezone)" } ?? "Opening archive…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch destination {
        case .insights:
            InsightsView(model: model)
                .toolbar {
                    ToolbarItem {
                        Button {
                            showInspector.toggle()
                        } label: {
                            Label("Inspector", systemImage: "sidebar.trailing")
                        }
                        .help("Show or hide the details pane")
                    }
                }
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

/// One row in the sidebar.
///
/// Hand rolled rather than a `List` row: the reference layout puts a stat on
/// the trailing edge of every row, and `List` selection styling fights that
/// with its own capsule.
private struct SidebarRow: View {
    var label: String
    var symbol: String
    var symbolSize: CGFloat = 11
    var trailing: String?
    var isSelected: Bool
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .frame(width: 14)
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Space.xs)
                if let trailing {
                    Text(trailing)
                        .font(Theme.numeric(10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 5)
            .background(background)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(isSelected ? Theme.rowHighlight : (isHovering ? Theme.rowHighlight.opacity(0.5) : .clear))
            .padding(.horizontal, Theme.Space.xs)
    }
}
