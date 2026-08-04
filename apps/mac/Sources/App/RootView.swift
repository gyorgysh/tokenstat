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
    /// Projects the user has collapsed. Stored as the exception rather than
    /// the rule, so a newly discovered project arrives expanded.
    @State private var collapsed: Set<String> = []

    /// The archive holds every project ever touched, which on a working
    /// machine is dozens. The sidebar shows the busiest and says how many it
    /// left out rather than silently truncating.
    private let workspaceLimit = 12

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

                // Real folders from the archive, each with the harnesses that
                // ran in it. Today the counts come from session history, which
                // is what the archive holds. When the terminal lands these same
                // rows gain live sessions, and clicking one opens it rather
                // than filtering a report.
                SectionLabel(text: "Workspaces", count: model.workspaces.count)
                    .padding(.horizontal, Theme.Space.m)
                    .padding(.top, Theme.Space.l)
                    .padding(.bottom, Theme.Space.xs)

                if model.workspaces.isEmpty {
                    Text("Run a scan to see your projects.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, Theme.Space.m)
                        .padding(.vertical, Theme.Space.xs)
                } else {
                    ForEach(model.workspaces.prefix(workspaceLimit)) { workspace in
                        WorkspaceRow(
                            workspace: workspace,
                            isExpanded: expanded.contains(workspace.id),
                            selectedHarness: selectedHarness(in: workspace),
                            onToggle: { toggle(workspace) },
                            onSelectProject: { select(project: workspace) },
                            onSelectHarness: { select(harness: $0) }
                        )
                    }
                    if model.workspaces.count > workspaceLimit {
                        Text("and \(model.workspaces.count - workspaceLimit) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, Theme.Space.xs)
                    }
                }
            }
            .padding(.bottom, Theme.Space.m)
        }
        .background(Theme.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 228, max: 300)
        .safeAreaInset(edge: .bottom) { accountFooter }
    }

    /// Expanded by default, so the harnesses in a project are visible without
    /// hunting. Collapsing is remembered per project instead.
    private var expanded: Set<String> {
        Set(model.workspaces.map(\.id)).subtracting(collapsed)
    }

    private func toggle(_ workspace: Workspace) {
        if collapsed.contains(workspace.id) {
            collapsed.remove(workspace.id)
        } else {
            collapsed.insert(workspace.id)
        }
    }

    private func selectedHarness(in workspace: Workspace) -> String? {
        guard destination == .insights, model.tab == .harnesses else { return nil }
        return model.selected?.key
    }

    private func select(project workspace: Workspace) {
        destination = .insights
        model.tab = .projects
        model.selected = model.byProject.first { $0.key == workspace.path }
    }

    private func select(harness row: SplitBucket) {
        destination = .insights
        model.tab = .harnesses
        model.selected = model.bySource.first { $0.key == row.split }
    }

    /// Who is signed in, pinned to the bottom of the sidebar with a menu.
    ///
    /// The archive line that used to live here moved into the inspector, which
    /// already had an Archive section. Two places saying where the numbers came
    /// from was one too many, and this corner is where people look for their
    /// account.
    private var accountFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            Menu {
                if account.signedIn {
                    Button("Account settings") { destination = .account }
                    Button("Sync now") { Task { await account.sync() } }
                        .disabled(account.isSyncing)
                    Divider()
                    Button("Sign out") { Task { await account.signOut() } }
                } else {
                    Button("Sign in to tokenstat.ai") {
                        destination = .account
                        account.signIn()
                    }
                    Divider()
                    Button("Account") { destination = .account }
                }
            } label: {
                accountLabel
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, Theme.Space.s)
        }
        .background(Theme.sidebar)
    }

    /// Avatar, handle, plan, chevron.
    ///
    /// The plan sits beside the handle rather than as a badge on the avatar.
    /// "Patron" is six characters and overflowed a 24pt circle, landing on top
    /// of the name.
    private var accountLabel: some View {
        HStack(spacing: Theme.Space.s) {
            Avatar(
                url: account.account?.avatar,
                handle: account.account?.handle,
                size: 22
            )

            if account.isSyncing {
                Text("Syncing…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: Theme.Space.xs) {
                    Text(account.account?.handle ?? "Not signed in")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let tier = account.account?.tier, !tier.isEmpty {
                        Text("·")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                        Text(tier.capitalized)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: Theme.Space.xs)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
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
                A terminal per project. Past sessions and running ones, with \
                Claude Code, Codex, OpenCode and the rest launched in place, and \
                the file and git changes for that folder in this pane.
                """,
                milestone: "Milestones 4 and 5 in docs/desktop-app.md"
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

/// A project folder and the harnesses that ran in it.
private struct WorkspaceRow: View {
    var workspace: Workspace
    var isExpanded: Bool
    var selectedHarness: String?
    var onToggle: () -> Void
    var onSelectProject: () -> Void
    var onSelectHarness: (SplitBucket) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                Button(action: onToggle) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // Disabled rather than hidden, so rows stay aligned whether or
                // not a project has harness attribution.
                .disabled(workspace.harnesses.isEmpty)
                .opacity(workspace.harnesses.isEmpty ? 0.25 : 1)

                Button(action: onSelectProject) {
                    HStack(spacing: Theme.Space.s) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(workspace.name)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Space.xs)
                        Text(formatTokens(workspace.tokens))
                            .font(Theme.numeric(10))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // The leaf name is what people call a project, but two
                // checkouts of one repository share it, so the full path is a
                // hover away.
                .help(workspace.path)
            }
            .padding(.leading, Theme.Space.s)
            .padding(.trailing, Theme.Space.m)
            .padding(.vertical, 4)

            if isExpanded {
                ForEach(workspace.harnesses) { harness in
                    Button {
                        onSelectHarness(harness)
                    } label: {
                        HStack(spacing: Theme.Space.s) {
                            HarnessMark(id: harness.split, size: 14)
                            Text(harnessName(harness.split))
                                .font(.system(size: 11))
                                .foregroundStyle(
                                    selectedHarness == harness.split ? Color.primary : .secondary
                                )
                                .lineLimit(1)
                            Spacer(minLength: Theme.Space.xs)
                            Text(formatTokens(harness.counters.total))
                                .font(Theme.numeric(10))
                                .foregroundStyle(.quaternary)
                        }
                        .padding(.leading, 30)
                        .padding(.trailing, Theme.Space.m)
                        .padding(.vertical, 3)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
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
